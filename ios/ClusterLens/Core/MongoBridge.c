#define BSON_STATIC
#define MONGOC_STATIC

#include "MongoBridge.h"

#include <bson/bson.h>
#include <mongoc/mongoc.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef struct {
   mongoc_client_t *value;
} CLMongoClient;

typedef struct {
   char *value;
   size_t length;
   size_t capacity;
} CLString;

static pthread_once_t g_mongo_once = PTHREAD_ONCE_INIT;

static void
cl_mongo_initialize(void)
{
   mongoc_init();
}

static void
cl_set_error(char **destination, const char *format, ...)
{
   if (!destination) {
      return;
   }

   char message[768];
   va_list args;
   va_start(args, format);
   vsnprintf(message, sizeof message, format, args);
   va_end(args);
   *destination = bson_strdup(message);
}

static CLString
cl_string_new(const char *initial)
{
   size_t initial_length = initial ? strlen(initial) : 0;
   CLString string = {bson_malloc(initial_length + 64), initial_length, initial_length + 64};
   if (initial_length > 0) {
      memcpy(string.value, initial, initial_length);
   }
   string.value[initial_length] = '\0';
   return string;
}

static void
cl_string_reserve(CLString *string, size_t additional)
{
   size_t required = string->length + additional + 1;
   if (required <= string->capacity) {
      return;
   }
   while (string->capacity < required) {
      string->capacity *= 2;
   }
   string->value = bson_realloc(string->value, string->capacity);
}

static void
cl_string_append(CLString *string, const char *value)
{
   size_t length = strlen(value);
   cl_string_reserve(string, length);
   memcpy(string->value + string->length, value, length + 1);
   string->length += length;
}

static void
cl_string_append_char(CLString *string, char value)
{
   cl_string_reserve(string, 1);
   string->value[string->length++] = value;
   string->value[string->length] = '\0';
}

static void
cl_string_append_format(CLString *string, const char *format, ...)
{
   va_list args;
   va_start(args, format);
   va_list copied;
   va_copy(copied, args);
   int needed = vsnprintf(NULL, 0, format, copied);
   va_end(copied);
   if (needed > 0) {
      cl_string_reserve(string, (size_t)needed);
      vsnprintf(string->value + string->length, (size_t)needed + 1, format, args);
      string->length += (size_t)needed;
   }
   va_end(args);
}

static char *
cl_string_take(CLString *string)
{
   char *value = string->value;
   string->value = NULL;
   string->length = 0;
   string->capacity = 0;
   return value;
}

static double
cl_monotonic_milliseconds(void)
{
   struct timespec value;
   clock_gettime(CLOCK_MONOTONIC, &value);
   return (double)value.tv_sec * 1000.0 + (double)value.tv_nsec / 1000000.0;
}

static char *
cl_document_json(const bson_t *document)
{
   return bson_as_relaxed_extended_json(document, NULL);
}

static bool
cl_document_value(const bson_t *input, const char *key, bson_t *value)
{
   bson_iter_t iterator;
   const uint8_t *data = NULL;
   uint32_t length = 0;
   if (!bson_iter_init_find(&iterator, input, key) || !BSON_ITER_HOLDS_DOCUMENT(&iterator)) {
      return false;
   }
   bson_iter_document(&iterator, &length, &data);
   return bson_init_static(value, data, length);
}

static bool
cl_array_value(const bson_t *input, const char *key, bson_t *value)
{
   bson_iter_t iterator;
   const uint8_t *data = NULL;
   uint32_t length = 0;
   if (!bson_iter_init_find(&iterator, input, key) || !BSON_ITER_HOLDS_ARRAY(&iterator)) {
      return false;
   }
   bson_iter_array(&iterator, &length, &data);
   return bson_init_static(value, data, length);
}

static int64_t
cl_integer_value(const bson_t *input, const char *key, int64_t fallback)
{
   bson_iter_t iterator;
   if (!bson_iter_init_find(&iterator, input, key) || !BSON_ITER_HOLDS_NUMBER(&iterator)) {
      return fallback;
   }
   return bson_iter_as_int64(&iterator);
}

static bool
cl_boolean_value(const bson_t *input, const char *key, bool fallback)
{
   bson_iter_t iterator;
   if (!bson_iter_init_find(&iterator, input, key) || !BSON_ITER_HOLDS_BOOL(&iterator)) {
      return fallback;
   }
   return bson_iter_bool(&iterator);
}

static const char *
cl_string_value(const bson_t *input, const char *key)
{
   bson_iter_t iterator;
   if (!bson_iter_init_find(&iterator, input, key) || !BSON_ITER_HOLDS_UTF8(&iterator)) {
      return NULL;
   }
   return bson_iter_utf8(&iterator, NULL);
}

static char *
cl_cursor_json_array(mongoc_cursor_t *cursor, int64_t maximum, char **error_message)
{
   CLString json = cl_string_new("[");
   const bson_t *document = NULL;
   int64_t count = 0;

   while (count < maximum && mongoc_cursor_next(cursor, &document)) {
      char *item = cl_document_json(document);
      if (count > 0) {
         cl_string_append_char(&json, ',');
      }
      cl_string_append(&json, item);
      bson_free(item);
      count++;
   }

   bson_error_t error;
   if (mongoc_cursor_error(cursor, &error)) {
      cl_set_error(error_message, "%s", error.message);
      bson_free(json.value);
      return NULL;
   }

   cl_string_append_char(&json, ']');
   return cl_string_take(&json);
}

static char *
cl_wrap_execution(const char *operation, double started_at, char *result_json)
{
   double elapsed = cl_monotonic_milliseconds() - started_at;
   CLString json = cl_string_new(NULL);
   cl_string_append_format(&json,
                           "{\"operation\":\"%s\",\"elapsedMS\":%.3f,\"result\":",
                           operation,
                           elapsed);
   cl_string_append(&json, result_json ? result_json : "null");
   cl_string_append_char(&json, '}');
   bson_free(result_json);
   return cl_string_take(&json);
}

CLMongoClientRef
cl_mongo_connect(const char *uri_text, char **error_message)
{
   if (error_message) {
      *error_message = NULL;
   }
   if (!uri_text || uri_text[0] == '\0') {
      cl_set_error(error_message, "The MongoDB connection string is empty.");
      return NULL;
   }

   pthread_once(&g_mongo_once, cl_mongo_initialize);

   bson_error_t error;
   mongoc_uri_t *uri = mongoc_uri_new_with_error(uri_text, &error);
   if (!uri) {
      cl_set_error(error_message, "Invalid MongoDB connection string: %s", error.message);
      return NULL;
   }

   if (mongoc_uri_get_option_as_int32(uri, MONGOC_URI_SERVERSELECTIONTIMEOUTMS, -1) < 0) {
      mongoc_uri_set_option_as_int32(uri, MONGOC_URI_SERVERSELECTIONTIMEOUTMS, 12000);
   }
   if (mongoc_uri_get_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, -1) < 0) {
      mongoc_uri_set_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, 10000);
   }

   mongoc_client_t *native_client = mongoc_client_new_from_uri(uri);
   mongoc_uri_destroy(uri);
   if (!native_client) {
      cl_set_error(error_message, "MongoDB could not create a client for this connection string.");
      return NULL;
   }

   mongoc_client_set_error_api(native_client, 2);
   mongoc_client_set_appname(native_client, "ClusterLens for iPhone");

   bson_t command = BSON_INITIALIZER;
   bson_t reply = BSON_INITIALIZER;
   BSON_APPEND_INT32(&command, "ping", 1);
   bool connected = mongoc_client_command_simple(native_client, "admin", &command, NULL, &reply, &error);
   bson_destroy(&reply);
   bson_destroy(&command);

   if (!connected) {
      cl_set_error(error_message, "%s", error.message);
      mongoc_client_destroy(native_client);
      return NULL;
   }

   CLMongoClient *client = bson_malloc0(sizeof *client);
   client->value = native_client;
   return client;
}

void
cl_mongo_disconnect(CLMongoClientRef reference)
{
   CLMongoClient *client = reference;
   if (!client) {
      return;
   }
   mongoc_client_destroy(client->value);
   bson_free(client);
}

char *
cl_mongo_list_databases(CLMongoClientRef reference, char **error_message)
{
   CLMongoClient *client = reference;
   if (!client) {
      cl_set_error(error_message, "There is no active MongoDB connection.");
      return NULL;
   }

   bson_t options = BSON_INITIALIZER;
   BSON_APPEND_BOOL(&options, "nameOnly", true);
   mongoc_cursor_t *cursor = mongoc_client_find_databases_with_opts(client->value, &options);
   bson_destroy(&options);
   char *json = cl_cursor_json_array(cursor, 500, error_message);
   mongoc_cursor_destroy(cursor);
   return json;
}

char *
cl_mongo_list_collections(CLMongoClientRef reference, const char *database_name, char **error_message)
{
   CLMongoClient *client = reference;
   if (!client || !database_name) {
      cl_set_error(error_message, "There is no active MongoDB connection.");
      return NULL;
   }

   mongoc_database_t *database = mongoc_client_get_database(client->value, database_name);
   bson_t options = BSON_INITIALIZER;
   BSON_APPEND_BOOL(&options, "nameOnly", true);
   mongoc_cursor_t *cursor = mongoc_database_find_collections_with_opts(database, &options);
   bson_destroy(&options);
   char *json = cl_cursor_json_array(cursor, 2000, error_message);
   mongoc_cursor_destroy(cursor);
   mongoc_database_destroy(database);
   return json;
}

char *
cl_mongo_execute(CLMongoClientRef reference,
                 const char *database_name,
                 const char *collection_name,
                 const char *operation,
                 const char *input_json,
                 char **error_message)
{
   CLMongoClient *client = reference;
   if (!client || !database_name || !collection_name || !operation || !input_json) {
      cl_set_error(error_message, "The query request is incomplete.");
      return NULL;
   }

   bson_error_t error;
   bson_t *input = bson_new_from_json((const uint8_t *)input_json, -1, &error);
   if (!input) {
      cl_set_error(error_message, "Invalid Extended JSON: %s", error.message);
      return NULL;
   }

   double started_at = cl_monotonic_milliseconds();
   mongoc_collection_t *collection =
      mongoc_client_get_collection(client->value, database_name, collection_name);
   char *result_json = NULL;

   bson_t empty = BSON_INITIALIZER;
   bson_t filter_view;
   bool has_filter = cl_document_value(input, "filter", &filter_view);
   const bson_t *filter = has_filter ? &filter_view : &empty;

   if (strcmp(operation, "find") == 0 || strcmp(operation, "findOne") == 0) {
      bson_t options = BSON_INITIALIZER;
      bson_t projection_view;
      bson_t sort_view;
      bool has_projection = cl_document_value(input, "projection", &projection_view);
      bool has_sort = cl_document_value(input, "sort", &sort_view);
      if (has_projection) {
         BSON_APPEND_DOCUMENT(&options, "projection", &projection_view);
      }
      if (has_sort) {
         BSON_APPEND_DOCUMENT(&options, "sort", &sort_view);
      }
      int64_t limit = strcmp(operation, "findOne") == 0 ? 1 : cl_integer_value(input, "limit", 50);
      limit = limit < 1 ? 1 : (limit > 100 ? 100 : limit);
      BSON_APPEND_INT64(&options, "limit", limit);
      int64_t skip = cl_integer_value(input, "skip", 0);
      if (skip > 0) {
         BSON_APPEND_INT64(&options, "skip", skip);
      }

      mongoc_cursor_t *cursor = mongoc_collection_find_with_opts(collection, filter, &options, NULL);
      if (strcmp(operation, "findOne") == 0) {
         const bson_t *document = NULL;
         if (mongoc_cursor_next(cursor, &document)) {
            result_json = cl_document_json(document);
         } else if (mongoc_cursor_error(cursor, &error)) {
            cl_set_error(error_message, "%s", error.message);
         } else {
            result_json = bson_strdup("null");
         }
      } else {
         result_json = cl_cursor_json_array(cursor, limit, error_message);
      }
      mongoc_cursor_destroy(cursor);
      if (has_projection) bson_destroy(&projection_view);
      if (has_sort) bson_destroy(&sort_view);
      bson_destroy(&options);
   } else if (strcmp(operation, "aggregate") == 0) {
      bson_t pipeline_array;
      if (!cl_array_value(input, "pipeline", &pipeline_array)) {
         cl_set_error(error_message, "Aggregate requires a pipeline array.");
      } else {
         bson_t pipeline = BSON_INITIALIZER;
         BSON_APPEND_ARRAY(&pipeline, "pipeline", &pipeline_array);
         mongoc_cursor_t *cursor =
            mongoc_collection_aggregate(collection, MONGOC_QUERY_NONE, &pipeline, NULL, NULL);
         result_json = cl_cursor_json_array(cursor, 100, error_message);
         mongoc_cursor_destroy(cursor);
         bson_destroy(&pipeline);
         bson_destroy(&pipeline_array);
      }
   } else if (strcmp(operation, "countDocuments") == 0) {
      int64_t count = mongoc_collection_count_documents(collection, filter, NULL, NULL, NULL, &error);
      if (count < 0) {
         cl_set_error(error_message, "%s", error.message);
      } else {
         result_json = bson_strdup_printf("%" PRId64, count);
      }
   } else if (strcmp(operation, "distinct") == 0) {
      const char *field = cl_string_value(input, "field");
      if (!field || field[0] == '\0') {
         cl_set_error(error_message, "Distinct requires a field name.");
      } else {
         bson_t command = BSON_INITIALIZER;
         bson_t reply = BSON_INITIALIZER;
         BSON_APPEND_UTF8(&command, "distinct", collection_name);
         BSON_APPEND_UTF8(&command, "key", field);
         BSON_APPEND_DOCUMENT(&command, "query", filter);
         if (mongoc_collection_command_simple(collection, &command, NULL, &reply, &error)) {
            result_json = cl_document_json(&reply);
         } else {
            cl_set_error(error_message, "%s", error.message);
         }
         bson_destroy(&reply);
         bson_destroy(&command);
      }
   } else if (strcmp(operation, "insertOne") == 0) {
      bson_t document;
      if (!cl_document_value(input, "document", &document)) {
         cl_set_error(error_message, "Insert One requires a document object.");
      } else {
         bson_t reply = BSON_INITIALIZER;
         if (mongoc_collection_insert_one(collection, &document, NULL, &reply, &error)) {
            result_json = cl_document_json(&reply);
         } else {
            cl_set_error(error_message, "%s", error.message);
         }
         bson_destroy(&reply);
         bson_destroy(&document);
      }
   } else if (strcmp(operation, "updateOne") == 0) {
      bson_t update;
      if (!cl_document_value(input, "update", &update)) {
         cl_set_error(error_message, "Update One requires an update object.");
      } else {
         bson_t options = BSON_INITIALIZER;
         bson_t reply = BSON_INITIALIZER;
         BSON_APPEND_BOOL(&options, "upsert", cl_boolean_value(input, "upsert", false));
         if (mongoc_collection_update_one(collection, filter, &update, &options, &reply, &error)) {
            result_json = cl_document_json(&reply);
         } else {
            cl_set_error(error_message, "%s", error.message);
         }
         bson_destroy(&reply);
         bson_destroy(&options);
         bson_destroy(&update);
      }
   } else if (strcmp(operation, "deleteOne") == 0) {
      bson_t reply = BSON_INITIALIZER;
      if (mongoc_collection_delete_one(collection, filter, NULL, &reply, &error)) {
         result_json = cl_document_json(&reply);
      } else {
         cl_set_error(error_message, "%s", error.message);
      }
      bson_destroy(&reply);
   } else {
      cl_set_error(error_message, "Unsupported query operation: %s", operation);
   }

   if (has_filter) bson_destroy(&filter_view);
   bson_destroy(&empty);
   bson_destroy(input);
   mongoc_collection_destroy(collection);

   return result_json ? cl_wrap_execution(operation, started_at, result_json) : NULL;
}

void
cl_mongo_free(char *value)
{
   bson_free(value);
}
