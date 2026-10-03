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
   mongoc_cursor_t *browse_cursor;
   bson_t *browse_pending;
} CLMongoClient;

typedef struct {
   char *value;
   size_t length;
   size_t capacity;
} CLString;

// These bound retained result JSON, not driver buffers or total process RSS.
#define CL_MAX_DOCUMENT_BYTES (1024 * 1024)
#define CL_MAX_RESULT_BYTES (4 * 1024 * 1024)
#define CL_MAX_INPUT_BYTES (256 * 1024)
#define CL_READ_MAX_TIME_MS 10000
#define CL_BATCH_SIZE 20
#define CL_BROWSE_PAGE_SIZE 20

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
cl_document_json(const bson_t *document, char **error_message)
{
   // Check BSON before serialization, then check expanded Extended JSON too.
   if (document->len > CL_MAX_DOCUMENT_BYTES) {
      cl_set_error(error_message, "A document exceeds the 1 MiB mobile preview limit. Use a projection to select fewer fields.");
      return NULL;
   }
   size_t length = 0;
   char *json = bson_as_canonical_extended_json(document, &length);
   if (!json || length > CL_MAX_DOCUMENT_BYTES) {
      bson_free(json);
      cl_set_error(error_message, "A document exceeds the 1 MiB JSON preview limit. Use a projection to select fewer fields.");
      return NULL;
   }
   return json;
}

static bool
cl_append_result_item(CLString *json, const char *item, bool needs_comma, char **error_message)
{
   size_t length = strlen(item);
   // Reserve the comma and closing bracket. A failure returns no partial result.
   size_t overhead = needs_comma ? 2 : 1;
   if (length > CL_MAX_RESULT_BYTES - overhead ||
       json->length > CL_MAX_RESULT_BYTES - overhead - length) {
      cl_set_error(error_message, "Results exceed the 4 MiB mobile preview limit. Reduce the limit or use a projection.");
      return false;
   }
   if (needs_comma) cl_string_append_char(json, ',');
   cl_string_append(json, item);
   return true;
}

static bool
cl_contains_write_stage(const bson_t *value)
{
   bson_iter_t iterator;
   if (!bson_iter_init(&iterator, value)) return true;
   while (bson_iter_next(&iterator)) {
      const char *key = bson_iter_key(&iterator);
      if (strcmp(key, "$out") == 0 || strcmp(key, "$merge") == 0) return true;
      if (BSON_ITER_HOLDS_DOCUMENT(&iterator) || BSON_ITER_HOLDS_ARRAY(&iterator)) {
         const uint8_t *data;
         uint32_t length;
         if (BSON_ITER_HOLDS_DOCUMENT(&iterator)) bson_iter_document(&iterator, &length, &data);
         else bson_iter_array(&iterator, &length, &data);
         bson_t child;
         if (!bson_init_static(&child, data, length)) return true;
         bool contains = cl_contains_write_stage(&child);
         bson_destroy(&child);
         if (contains) return true;
      }
   }
   return false;
}

static bool
cl_contains_javascript(const bson_t *value)
{
   bson_iter_t it;
   if (!bson_iter_init(&it, value)) return true;
   while (bson_iter_next(&it)) {
      const char *key = bson_iter_key(&it);
      if (!strcmp(key, "$where") || !strcmp(key, "$function") || !strcmp(key, "$accumulator") ||
          bson_iter_type(&it) == BSON_TYPE_CODE || bson_iter_type(&it) == BSON_TYPE_CODEWSCOPE) return true;
      if (BSON_ITER_HOLDS_DOCUMENT(&it) || BSON_ITER_HOLDS_ARRAY(&it)) {
         bson_iter_t child;
         if (!bson_iter_recurse(&it, &child)) return true;
         const uint8_t *data; uint32_t length;
         if (BSON_ITER_HOLDS_DOCUMENT(&it)) bson_iter_document(&it, &length, &data);
         else bson_iter_array(&it, &length, &data);
         bson_t nested;
         if (!bson_init_static(&nested, data, length)) return true;
         bool blocked = cl_contains_javascript(&nested);
         bson_destroy(&nested);
         if (blocked) return true;
      }
   }
   return false;
}

static bool
cl_confirmed_namespace(const bson_t *input, const char *database, const char *collection)
{
   if (!*database || !*collection || strlen(collection) > 200 || strchr(collection, '$') || !strncmp(collection, "system.", 7)) return false;
   bson_iter_t confirmation;
   if (!bson_iter_init_find(&confirmation, input, "confirmNamespace") || !BSON_ITER_HOLDS_UTF8(&confirmation)) return false;
   char *expected = bson_strdup_printf("%s.%s", database, collection);
   uint32_t length;
   const char *actual = bson_iter_utf8(&confirmation, &length);
   bool matches = strlen(expected) == length && !memcmp(expected, actual, length);
   bson_free(expected);
   return matches;
}

static bool
cl_configure_uri(mongoc_uri_t *uri, const char *ca_file, char **error_message)
{
   const char *unsafe_options[] = {
      MONGOC_URI_TLSINSECURE, MONGOC_URI_TLSALLOWINVALIDCERTIFICATES,
      MONGOC_URI_TLSALLOWINVALIDHOSTNAMES, MONGOC_URI_TLSDISABLECERTIFICATEREVOCATIONCHECK,
      MONGOC_URI_TLSDISABLEOCSPENDPOINTCHECK
   };
   if (!mongoc_uri_get_option_as_bool(uri, MONGOC_URI_TLS, true)) {
      cl_set_error(error_message, "ClusterLens requires TLS. Disabled TLS is not supported.");
      return false;
   }
   for (size_t i = 0; i < sizeof unsafe_options / sizeof unsafe_options[0]; i++) {
      if (mongoc_uri_get_option_as_bool(uri, unsafe_options[i], false)) {
         cl_set_error(error_message, "ClusterLens requires certificate and hostname verification.");
         return false;
      }
   }
   if (!ca_file || !*ca_file ||
       !mongoc_uri_set_option_as_bool(uri, MONGOC_URI_TLS, true) ||
       !mongoc_uri_set_option_as_utf8(uri, MONGOC_URI_TLSCAFILE, ca_file)) {
      cl_set_error(error_message, "The bundled TLS certificate store is unavailable.");
      return false;
   }
   const char *timeouts[] = { MONGOC_URI_SERVERSELECTIONTIMEOUTMS, MONGOC_URI_CONNECTTIMEOUTMS, MONGOC_URI_SOCKETTIMEOUTMS };
   const int32_t ceilings[] = { 12000, 10000, 15000 };
   for (size_t i = 0; i < sizeof timeouts / sizeof timeouts[0]; i++) {
      int32_t requested = mongoc_uri_get_option_as_int32(uri, timeouts[i], 0);
      int32_t bounded = requested > 0 && requested < ceilings[i] ? requested : ceilings[i];
      if (!mongoc_uri_set_option_as_int32(uri, timeouts[i], bounded)) {
         cl_set_error(error_message, "MongoDB could not configure a bounded network timeout.");
         return false;
      }
   }
   return true;
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
      char *item = cl_document_json(document, error_message);
      if (!item || !cl_append_result_item(&json, item, count > 0, error_message)) {
         bson_free(item);
         bson_free(json.value);
         return NULL;
      }
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
cl_mongo_connect(const char *uri_text, const char *ca_file, char **error_message)
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
      cl_set_error(error_message, "Invalid MongoDB connection string. Check its syntax and options.");
      return NULL;
   }

   if (!cl_configure_uri(uri, ca_file, error_message)) {
      mongoc_uri_destroy(uri);
      return NULL;
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
   cl_mongo_browse_close(client);
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
   BSON_APPEND_INT64(&options, "maxTimeMS", CL_READ_MAX_TIME_MS);
   // listDatabases returns an array, not a server cursor; it has no batchSize.
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
   BSON_APPEND_INT64(&options, "maxTimeMS", CL_READ_MAX_TIME_MS);
   BSON_APPEND_INT32(&options, "batchSize", CL_BATCH_SIZE);
   mongoc_cursor_t *cursor = mongoc_database_find_collections_with_opts(database, &options);
   bson_destroy(&options);
   char *json = cl_cursor_json_array(cursor, 2000, error_message);
   mongoc_cursor_destroy(cursor);
   mongoc_database_destroy(database);
   return json;
}

void
cl_mongo_browse_close(CLMongoClientRef reference)
{
   CLMongoClient *client = reference;
   if (!client) return;
   if (client->browse_pending) bson_destroy(client->browse_pending);
   if (client->browse_cursor) mongoc_cursor_destroy(client->browse_cursor);
   client->browse_pending = NULL;
   client->browse_cursor = NULL;
}

static void
cl_browse_options(bson_t *options)
{
   bson_init(options);
   bson_t sort = BSON_INITIALIZER;
   BSON_APPEND_INT32(&sort, "_id", 1);
   BSON_APPEND_DOCUMENT(options, "sort", &sort);
   bson_destroy(&sort);
   // Binary string ordering avoids locale-equivalent _id sort boundaries.
   bson_t collation = BSON_INITIALIZER;
   BSON_APPEND_UTF8(&collation, "locale", "simple");
   BSON_APPEND_DOCUMENT(options, "collation", &collation);
   bson_destroy(&collation);
   BSON_APPEND_INT32(options, "batchSize", CL_BROWSE_PAGE_SIZE + 1);
   BSON_APPEND_INT64(options, "maxTimeMS", CL_READ_MAX_TIME_MS);
   // No skip, limit, noCursorTimeout, or requery-based continuation.
}

char *
cl_mongo_browse_next(CLMongoClientRef reference, char **error_message)
{
   if (error_message) *error_message = NULL;
   CLMongoClient *client = reference;
   if (!client || !client->browse_cursor) {
      cl_set_error(error_message, "This browsing cursor is closed. Restart browsing to continue.");
      return NULL;
   }
   double started_at = cl_monotonic_milliseconds();
   CLString json = cl_string_new("[");
   int count = 0;
   bool has_more = false;

   while (true) {
      const bson_t *document = client->browse_pending;
      if (!document && !mongoc_cursor_next(client->browse_cursor, &document)) {
         bson_error_t error;
         if (mongoc_cursor_error(client->browse_cursor, &error)) {
            cl_set_error(error_message, "%s", error.message);
            goto failure;
         }
         break;
      }
      // Validate the lookahead too, so an oversized document never sits retained.
      char *item = cl_document_json(document, error_message);
      if (!item) goto failure;
      size_t length = strlen(item);
      size_t overhead = count > 0 ? 2 : 1; // comma and closing array bracket
      bool fits = length <= CL_MAX_RESULT_BYTES - overhead &&
                  json.length <= CL_MAX_RESULT_BYTES - overhead - length;
      if (count == CL_BROWSE_PAGE_SIZE || !fits) {
         // Preserve the exact BSON document, including numeric _id types. It is
         // consumed only on the next page; never refetch a range boundary.
         if (!client->browse_pending) client->browse_pending = bson_copy(document);
         bson_free(item);
         has_more = true;
         break;
      }
      if (!cl_append_result_item(&json, item, count > 0, error_message)) {
         bson_free(item);
         goto failure;
      }
      bson_free(item);
      if (client->browse_pending) {
         bson_destroy(client->browse_pending);
         client->browse_pending = NULL;
      }
      count++;
   }

   if (!has_more) cl_mongo_browse_close(client);
   cl_string_append_char(&json, ']');
   CLString reply = cl_string_new("{\"documents\":");
   cl_string_append(&reply, json.value);
   cl_string_append_format(&reply, ",\"hasMore\":%s,\"elapsedMS\":%.3f}",
                           has_more ? "true" : "false", cl_monotonic_milliseconds() - started_at);
   bson_free(json.value);
   return cl_string_take(&reply);

failure:
   bson_free(json.value);
   cl_mongo_browse_close(client);
   return NULL;
}

char *
cl_mongo_browse_filtered(CLMongoClientRef reference, const char *database_name,
                         const char *collection_name, const char *query_json, char **error_message)
{
   CLMongoClient *client = reference;
   if (!client || !client->value || !database_name || !collection_name || !query_json) {
      cl_set_error(error_message, "The browsing request is incomplete.");
      return NULL;
   }
   if (strlen(query_json) > CL_MAX_INPUT_BYTES) {
      cl_set_error(error_message, "Query input exceeds the 256 KiB mobile limit.");
      return NULL;
   }
   bson_error_t error;
   bson_t *query = bson_new_from_json((const uint8_t *)query_json, -1, &error);
   if (!query) { cl_set_error(error_message, "Invalid Extended JSON: %s", error.message); return NULL; }
   if (cl_contains_javascript(query)) {
      cl_set_error(error_message, "Server-side JavaScript is not supported.");
      bson_destroy(query); return NULL;
   }
   bson_t filter, projection, sort;
   bool has_filter = cl_document_value(query, "filter", &filter);
   bool has_projection = cl_document_value(query, "projection", &projection);
   bool has_sort = cl_document_value(query, "sort", &sort);
   char *result = NULL;
   if (!has_filter || !has_projection || !has_sort) {
      cl_set_error(error_message, "Filter, projection and sort must be objects.");
   } else {
      cl_mongo_browse_close(client);
      mongoc_collection_t *collection = mongoc_client_get_collection(client->value, database_name, collection_name);
      bson_t options;
      cl_browse_options(&options);
      // Replace the default sort without creating duplicate BSON keys.
      bson_t filtered_options = BSON_INITIALIZER;
      bson_copy_to_excluding_noinit(&options, &filtered_options, "sort", NULL);
      BSON_APPEND_DOCUMENT(&filtered_options, "sort", &sort);
      BSON_APPEND_DOCUMENT(&filtered_options, "projection", &projection);
      client->browse_cursor = mongoc_collection_find_with_opts(collection, &filter, &filtered_options, NULL);
      bson_destroy(&filtered_options);
      bson_destroy(&options);
      mongoc_collection_destroy(collection);
      result = cl_mongo_browse_next(client, error_message);
   }
   if (has_filter) bson_destroy(&filter);
   if (has_projection) bson_destroy(&projection);
   if (has_sort) bson_destroy(&sort);
   bson_destroy(query);
   return result;
}

char *
cl_mongo_browse_start(CLMongoClientRef reference, const char *database_name,
                      const char *collection_name, char **error_message)
{
   return cl_mongo_browse_filtered(reference, database_name, collection_name,
      "{\"filter\":{},\"projection\":{},\"sort\":{\"_id\":1}}", error_message);
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

   if (strlen(input_json) > CL_MAX_INPUT_BYTES) {
      cl_set_error(error_message, "Query input exceeds the 256 KiB mobile limit.");
      return NULL;
   }
   bson_error_t error;
   bson_t *input = bson_new_from_json((const uint8_t *)input_json, -1, &error);
   if (!input) {
      cl_set_error(error_message, "Invalid Extended JSON: %s", error.message);
      return NULL;
   }

   if (cl_contains_javascript(input)) {
      cl_set_error(error_message, "Server-side JavaScript is not supported.");
      bson_destroy(input); return NULL;
   }
   if ((!strcmp(operation, "createCollection") || !strcmp(operation, "dropCollection")) &&
       !cl_confirmed_namespace(input, database_name, collection_name)) {
      cl_set_error(error_message, "Collection action requires its exact confirmed database.collection namespace.");
      bson_destroy(input); return NULL;
   }
   if (strcmp(operation, "aggregate") == 0 && cl_contains_write_stage(input)) {
      cl_set_error(error_message, "Aggregation is read-only in ClusterLens. $out and $merge are not supported.");
      bson_destroy(input);
      return NULL;
   }
   bson_t write_filter;
   if (strcmp(operation, "updateOne") == 0 || strcmp(operation, "deleteOne") == 0) {
      if (!cl_document_value(input, "filter", &write_filter)) {
         cl_set_error(error_message, "Update and delete require a non-empty filter. Prefer a specific _id.");
         bson_destroy(input);
         return NULL;
      }
      bool empty_filter = bson_empty(&write_filter);
      bson_destroy(&write_filter);
      if (empty_filter) {
         cl_set_error(error_message, "Update and delete require a non-empty filter. Prefer a specific _id.");
         bson_destroy(input);
         return NULL;
      }
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
      BSON_APPEND_INT32(&options, "batchSize", CL_BATCH_SIZE);
      BSON_APPEND_INT64(&options, "maxTimeMS", CL_READ_MAX_TIME_MS);
      int64_t skip = cl_integer_value(input, "skip", 0);
      if (skip > 0) {
         BSON_APPEND_INT64(&options, "skip", skip);
      }

      mongoc_cursor_t *cursor = mongoc_collection_find_with_opts(collection, filter, &options, NULL);
      if (strcmp(operation, "findOne") == 0) {
         const bson_t *document = NULL;
         if (mongoc_cursor_next(cursor, &document)) {
            result_json = cl_document_json(document, error_message);
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
         bson_t options = BSON_INITIALIZER;
         BSON_APPEND_INT32(&options, "batchSize", CL_BATCH_SIZE);
         BSON_APPEND_INT64(&options, "maxTimeMS", CL_READ_MAX_TIME_MS);
         BSON_APPEND_BOOL(&options, "allowDiskUse", false);
         mongoc_cursor_t *cursor =
            mongoc_collection_aggregate(collection, MONGOC_QUERY_NONE, &pipeline, &options, NULL);
         bson_destroy(&options);
         result_json = cl_cursor_json_array(cursor, 100, error_message);
         mongoc_cursor_destroy(cursor);
         bson_destroy(&pipeline);
         bson_destroy(&pipeline_array);
      }
   } else if (strcmp(operation, "countDocuments") == 0) {
      bson_t options = BSON_INITIALIZER;
      BSON_APPEND_INT64(&options, "maxTimeMS", CL_READ_MAX_TIME_MS);
      int64_t count = mongoc_collection_count_documents(collection, filter, &options, NULL, NULL, &error);
      bson_destroy(&options);
      if (count < 0) {
         cl_set_error(error_message, "%s", error.message);
      } else {
         result_json = bson_strdup_printf("{\"$numberLong\":\"%" PRId64 "\"}", count);
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
         BSON_APPEND_INT64(&command, "maxTimeMS", CL_READ_MAX_TIME_MS);
         if (mongoc_collection_command_simple(collection, &command, NULL, &reply, &error)) {
            result_json = cl_document_json(&reply, error_message);
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
            result_json = cl_document_json(&reply, error_message);
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
            result_json = cl_document_json(&reply, error_message);
         } else {
            cl_set_error(error_message, "%s", error.message);
         }
         bson_destroy(&reply);
         bson_destroy(&options);
         bson_destroy(&update);
      }
   } else if (strcmp(operation, "createCollection") == 0) {
      mongoc_database_t *database = mongoc_client_get_database(client->value, database_name);
      mongoc_collection_t *created = mongoc_database_create_collection(database, collection_name, NULL, &error);
      if (created) {
         result_json = bson_strdup("{\"acknowledged\":true}");
         mongoc_collection_destroy(created);
      } else { cl_set_error(error_message, "%s", error.message); }
      mongoc_database_destroy(database);
   } else if (strcmp(operation, "dropCollection") == 0) {
      if (mongoc_collection_drop_with_opts(collection, NULL, &error)) {
         result_json = bson_strdup("{\"acknowledged\":true}");
      } else { cl_set_error(error_message, "%s", error.message); }
   } else if (strcmp(operation, "deleteOne") == 0) {
      bson_t reply = BSON_INITIALIZER;
      if (mongoc_collection_delete_one(collection, filter, NULL, &reply, &error)) {
         result_json = cl_document_json(&reply, error_message);
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
