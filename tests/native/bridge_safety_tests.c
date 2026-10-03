// Exercise the production bridge's internal boundaries with synthetic BSON only.
// No connect/execute call is allowed for a valid query in this harness.
#include "../../ios/ClusterLens/Core/MongoBridge.c"
#include <assert.h>

static bson_t *parse(const char *json) {
   bson_error_t error;
   bson_t *value = bson_new_from_json((const uint8_t *)json, -1, &error);
   assert(value);
   return value;
}

static void test_aggregation_guards(void) {
   const char *blocked[] = {
      "{\"pipeline\":[{\"$out\":\"archive\"}]}",
      "{\"pipeline\":[{\"$merge\":{\"into\":\"archive\"}}]}",
      "{\"pipeline\":[{\"$facet\":{\"nested\":[{\"$merge\":\"archive\"}]}}]}"
   };
   for (size_t i = 0; i < sizeof blocked / sizeof blocked[0]; i++) {
      bson_t *value = parse(blocked[i]);
      assert(cl_contains_write_stage(value));
      bson_destroy(value);
   }
   bson_t *value = parse("{\"pipeline\":[{\"$match\":{}},{\"$limit\":50}]}");
   assert(!cl_contains_write_stage(value));
   bson_destroy(value);
}

static void test_tls_and_timeout_policy(void) {
   const char *blocked[] = {
      "tls=false", "ssl=false", "tlsInsecure=true", "tlsAllowInvalidCertificates=true",
      "tlsAllowInvalidHostnames=true", "tlsDisableOCSPEndpointCheck=true",
      "tlsDisableCertificateRevocationCheck=true"
   };
   for (size_t i = 0; i < sizeof blocked / sizeof blocked[0]; i++) {
      char *text = bson_strdup_printf("mongodb://example.invalid/?%s", blocked[i]);
      mongoc_uri_t *uri = mongoc_uri_new(text);
      assert(uri);
      char *error = NULL;
      assert(!cl_configure_uri(uri, "/synthetic/ca.pem", &error));
      assert(error);
      bson_free(error);
      bson_free(text);
      mongoc_uri_destroy(uri);
   }
   mongoc_uri_t *uri = mongoc_uri_new("mongodb://example.invalid/?socketTimeoutMS=0&connectTimeoutMS=999999&serverSelectionTimeoutMS=200");
   assert(uri);
   char *error = NULL;
   assert(cl_configure_uri(uri, "/synthetic/ca.pem", &error));
   assert(error == NULL);
   assert(mongoc_uri_get_tls(uri));
   assert(mongoc_uri_get_option_as_int32(uri, MONGOC_URI_SOCKETTIMEOUTMS, 0) == 15000);
   assert(mongoc_uri_get_option_as_int32(uri, MONGOC_URI_CONNECTTIMEOUTMS, 0) == 10000);
   assert(mongoc_uri_get_option_as_int32(uri, MONGOC_URI_SERVERSELECTIONTIMEOUTMS, 0) == 200);
   assert(!cl_configure_uri(uri, NULL, &error));
   assert(error);
   bson_free(error);
   mongoc_uri_destroy(uri);
}

static void test_document_byte_budget(void) {
   bson_t value = BSON_INITIALIZER;
   char *large = bson_malloc(CL_MAX_DOCUMENT_BYTES + 1);
   memset(large, 'x', CL_MAX_DOCUMENT_BYTES);
   large[CL_MAX_DOCUMENT_BYTES] = 0;
   BSON_APPEND_UTF8(&value, "large", large);
   char *error = NULL;
   assert(cl_document_json(&value, &error) == NULL);
   assert(error);
   bson_free(error);
   bson_destroy(&value);

   // Escaping can make JSON exceed the limit even while BSON is under it.
   bson_init(&value);
   memset(large, '\n', CL_MAX_DOCUMENT_BYTES / 2 + 1);
   large[CL_MAX_DOCUMENT_BYTES / 2 + 1] = 0;
   BSON_APPEND_UTF8(&value, "escaped", large);
   assert(value.len < CL_MAX_DOCUMENT_BYTES);
   error = NULL;
   assert(cl_document_json(&value, &error) == NULL);
   assert(error);
   bson_free(error);
   bson_free(large);
   bson_destroy(&value);

   bson_t *small = parse("{\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"},\"name\":\"sample\"}");
   error = NULL;
   char *json = cl_document_json(small, &error);
   assert(json && !error && strstr(json, "$oid"));
   bson_free(json);
   bson_destroy(small);
}

static void test_total_byte_budget_boundaries(void) {
   CLString result = cl_string_new("[");
   char *item = bson_malloc(CL_MAX_RESULT_BYTES);
   memset(item, ' ', CL_MAX_RESULT_BYTES - 2);
   item[CL_MAX_RESULT_BYTES - 2] = 0;
   char *error = NULL;
   assert(cl_append_result_item(&result, item, false, &error));
   assert(result.length == CL_MAX_RESULT_BYTES - 1);
   size_t before = result.length;
   assert(!cl_append_result_item(&result, "{}", true, &error));
   assert(result.length == before && error);
   bson_free(error);
   bson_free(item);
   bson_free(result.value);
}

static void test_cursor_is_bounded_without_network(void) {
   // id:0 means no getMore is possible; all 101 documents are synthetic firstBatch.
   mongoc_client_t *client = mongoc_client_new("mongodb://example.invalid/");
   assert(client);
   bson_t *reply = bson_new();
   bson_t cursor_doc, batch;
   BSON_APPEND_DOCUMENT_BEGIN(reply, "cursor", &cursor_doc);
   BSON_APPEND_INT64(&cursor_doc, "id", 0);
   BSON_APPEND_UTF8(&cursor_doc, "ns", "fixtures.items");
   bson_append_array_unsafe_begin(&cursor_doc, "firstBatch", -1, &batch);
   for (int i = 0; i < 101; i++) {
      char key[16];
      snprintf(key, sizeof key, "%d", i);
      bson_t item;
      BSON_APPEND_DOCUMENT_BEGIN(&batch, key, &item);
      BSON_APPEND_INT32(&item, "index", i);
      bson_append_document_end(&batch, &item);
   }
   bson_append_array_end(&cursor_doc, &batch);
   bson_append_document_end(reply, &cursor_doc);
   BSON_APPEND_DOUBLE(reply, "ok", 1);
   mongoc_cursor_t *cursor = mongoc_cursor_new_from_command_reply_with_opts(client, reply, NULL);
   char *error = NULL;
   char *json = cl_cursor_json_array(cursor, 100, &error);
   assert(json && !error);
   char *wrapper = bson_strdup_printf("{\"items\":%s}", json);
   bson_t *decoded = parse(wrapper);
   bson_t items;
   assert(cl_array_value(decoded, "items", &items));
   assert(bson_count_keys(&items) == 100);
   bson_destroy(&items);
   bson_destroy(decoded);
   bson_free(wrapper);
   bson_free(json);
   mongoc_cursor_destroy(cursor);
   mongoc_client_destroy(client);
}

static void test_unsafe_execution_stops_before_client_use(void) {
   // A null native value proves rejected queries stop before touching the driver.
   CLMongoClient client = {0};
   const char *inputs[] = {"{}", "{\"filter\":null}", "{\"filter\":[]}", "{\"filter\":{}}"};
   for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++) {
      for (int operation = 0; operation < 2; operation++) {
         char *error = NULL;
         assert(!cl_mongo_execute(&client, "fixtures", "items", operation ? "deleteOne" : "updateOne", inputs[i], &error));
         assert(error);
         bson_free(error);
      }
   }
   char *error = NULL;
   assert(!cl_mongo_execute(&client, "fixtures", "items", "aggregate", "{\"pipeline\":[{\"$out\":\"archive\"}]}", &error));
   assert(error);
   bson_free(error);
   char *large = bson_malloc0(CL_MAX_INPUT_BYTES + 2);
   memset(large, ' ', CL_MAX_INPUT_BYTES + 1);
   error = NULL;
   assert(!cl_mongo_execute(&client, "fixtures", "items", "find", large, &error));
   assert(error);
   bson_free(error);
   bson_free(large);
}

static void test_script_and_collection_guards(void) {
   CLMongoClient client = {0};
   const char *blocked[] = {
      "{\"filter\":{\"$where\":\"return true\"}}",
      "{\"pipeline\":[{\"$project\":{\"x\":{\"$function\":{}}}}]}",
      "{\"filter\":{\"x\":{\"$code\":\"return true\"}}}"
   };
   for (size_t i = 0; i < sizeof blocked / sizeof blocked[0]; i++) {
      char *error = NULL;
      assert(!cl_mongo_execute(&client, "fixture", "orders", "find", blocked[i], &error));
      assert(error); bson_free(error);
   }
   const char *invalid[] = {"{}", "{\"confirmNamespace\":\"other.orders\"}"};
   for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; i++) {
      char *error = NULL;
      assert(!cl_mongo_execute(&client, "fixture", "orders", "dropCollection", invalid[i], &error));
      assert(error); bson_free(error);
   }
   bson_t *confirmation = parse("{\"confirmNamespace\":\"fixture.orders\"}");
   assert(cl_confirmed_namespace(confirmation, "fixture", "orders"));
   assert(!cl_confirmed_namespace(confirmation, "fixture", "other"));
   assert(!cl_confirmed_namespace(confirmation, "fixture", "system.users"));
   bson_destroy(confirmation);
}

static mongoc_cursor_t *synthetic_browse_cursor(mongoc_client_t *client, int count, size_t payload_bytes) {
   bson_t *reply = bson_new();
   bson_t cursor_doc, batch;
   BSON_APPEND_DOCUMENT_BEGIN(reply, "cursor", &cursor_doc);
   BSON_APPEND_INT64(&cursor_doc, "id", 0); // all data is local; no getMore/network
   BSON_APPEND_UTF8(&cursor_doc, "ns", "fixtures.items");
   bson_append_array_unsafe_begin(&cursor_doc, "firstBatch", -1, &batch);
   char *payload = bson_malloc(payload_bytes + 1);
   memset(payload, 'x', payload_bytes);
   payload[payload_bytes] = 0;
   for (int i = 0; i < count; i++) {
      char key[16];
      snprintf(key, sizeof key, "%d", i);
      bson_t item;
      BSON_APPEND_DOCUMENT_BEGIN(&batch, key, &item);
      // Duplicate sort keys intentionally straddle page boundaries. The cursor
      // must retain every distinct ordinal without deduplicating or refetching.
      BSON_APPEND_INT64(&item, "_id", INT64_C(9007199254740993) + i / 3);
      BSON_APPEND_INT32(&item, "ordinal", i);
      if (payload_bytes) BSON_APPEND_UTF8(&item, "payload", payload);
      bson_append_document_end(&batch, &item);
   }
   bson_free(payload);
   bson_append_array_end(&cursor_doc, &batch);
   bson_append_document_end(reply, &cursor_doc);
   BSON_APPEND_DOUBLE(reply, "ok", 1);
   return mongoc_cursor_new_from_command_reply_with_opts(client, reply, NULL);
}

static void test_browse_order_and_boundaries(void) {
   bson_t options, sort, collation;
   cl_browse_options(&options);
   assert(cl_document_value(&options, "sort", &sort));
   assert(bson_count_keys(&sort) == 1 && cl_integer_value(&sort, "_id", 0) == 1);
   assert(cl_document_value(&options, "collation", &collation));
   assert(strcmp(cl_string_value(&collation, "locale"), "simple") == 0);
   assert(!bson_has_field(&options, "skip") && !bson_has_field(&options, "limit"));
   assert(!bson_has_field(&options, "noCursorTimeout"));
   assert(cl_integer_value(&options, "batchSize", 0) == CL_BROWSE_PAGE_SIZE + 1);
   assert(cl_integer_value(&options, "maxTimeMS", 0) == CL_READ_MAX_TIME_MS);
   bson_destroy(&sort);
   bson_destroy(&collation);
   bson_destroy(&options);

   const int sizes[] = {0, 1, 19, 20, 21, 40, 41, 101, 1001};
   for (size_t run = 0; run < sizeof sizes / sizeof sizes[0] + 1; run++) {
      bool byte_boundary = run == sizeof sizes / sizeof sizes[0];
      int total = byte_boundary ? 9 : sizes[run];
      CLMongoClient client = {0};
      client.value = mongoc_client_new("mongodb://example.invalid/");
      client.browse_cursor = synthetic_browse_cursor(client.value, total, byte_boundary ? 1000000 : 0);
      int seen = 0;
      bool more;
      do {
         char *error = NULL;
         char *json = cl_mongo_browse_next(&client, &error);
         assert(json && !error);
         assert(strlen(json) <= CL_MAX_RESULT_BYTES + 256);
         bson_t *reply = parse(json);
         bson_t documents;
         assert(cl_array_value(reply, "documents", &documents));
         uint32_t count = bson_count_keys(&documents);
         assert(count <= CL_BROWSE_PAGE_SIZE);
         if (byte_boundary) assert(count <= 4);
         bson_iter_t iterator;
         assert(bson_iter_init(&iterator, &documents));
         while (bson_iter_next(&iterator)) {
            const uint8_t *data;
            uint32_t length;
            bson_iter_document(&iterator, &length, &data);
            bson_t document;
            assert(bson_init_static(&document, data, length));
            assert(cl_integer_value(&document, "ordinal", -1) == seen);
            assert(cl_integer_value(&document, "_id", 0) == INT64_C(9007199254740993) + seen / 3);
            seen++;
            bson_destroy(&document);
         }
         more = cl_boolean_value(reply, "hasMore", false);
         assert(more == (seen < total));
         if (more) {
            assert(client.browse_cursor && client.browse_pending);
            assert(client.browse_pending->len <= CL_MAX_DOCUMENT_BYTES);
         } else {
            assert(!client.browse_cursor && !client.browse_pending);
         }
         bson_destroy(&documents);
         bson_destroy(reply);
         bson_free(json);
      } while (more);
      assert(seen == total);
      char *error = NULL;
      assert(!cl_mongo_browse_next(&client, &error) && error);
      bson_free(error);
      cl_mongo_browse_close(&client); // repeated close is safe
      mongoc_client_destroy(client.value);
   }
}

static void test_browse_failure_and_close(void) {
   CLMongoClient client = {0};
   client.value = mongoc_client_new("mongodb://example.invalid/");
   client.browse_cursor = synthetic_browse_cursor(client.value, 21, 0);
   char *error = NULL;
   char *json = cl_mongo_browse_next(&client, &error);
   assert(json && client.browse_pending);
   bson_free(json);
   cl_mongo_browse_close(&client);
   assert(!client.browse_pending && !client.browse_cursor);
   client.browse_cursor = synthetic_browse_cursor(client.value, 1, CL_MAX_DOCUMENT_BYTES);
   assert(!cl_mongo_browse_next(&client, &error));
   assert(error && !client.browse_cursor && !client.browse_pending);
   bson_free(error);
   error = NULL;
   client.browse_cursor = mongoc_cursor_new_from_command_reply_with_opts(client.value,
      parse("{\"ok\":0,\"code\":50,\"errmsg\":\"synthetic timeout\"}"), NULL);
   assert(!cl_mongo_browse_next(&client, &error));
   assert(error && !client.browse_cursor && !client.browse_pending);
   bson_free(error);
   mongoc_client_destroy(client.value);
}

static const char *numeric_fixture =
   "{\"int32\":{\"$numberInt\":\"42\"},"
   "\"large\":{\"$numberLong\":\"9007199254740993\"},"
   "\"max\":{\"$numberLong\":\"9223372036854775807\"},"
   "\"min\":{\"$numberLong\":\"-9223372036854775808\"},"
   "\"decimal\":{\"$numberDecimal\":\"1234567890.123456789012345678901234\"},"
   "\"double\":{\"$numberDouble\":\"1.25\"},"
   "\"negativeZero\":{\"$numberDouble\":\"-0.0\"},"
   "\"nan\":{\"$numberDouble\":\"NaN\"},"
   "\"date\":{\"$date\":{\"$numberLong\":\"1767225600000\"}}}";

static void assert_same_numeric_values(const bson_t *expected, const bson_t *actual) {
   // Swift sorts object keys while formatting; compare BSON values by key.
   assert(bson_count_keys(expected) == bson_count_keys(actual));
   bson_iter_t source;
   assert(bson_iter_init(&source, expected));
   while (bson_iter_next(&source)) {
      bson_iter_t result;
      assert(bson_iter_init_find(&result, actual, bson_iter_key(&source)));
      bson_t left = BSON_INITIALIZER, right = BSON_INITIALIZER;
      BSON_APPEND_VALUE(&left, "value", bson_iter_value(&source));
      BSON_APPEND_VALUE(&right, "value", bson_iter_value(&result));
      assert(bson_equal(&left, &right));
      bson_destroy(&left);
      bson_destroy(&right);
   }
}

static void test_canonical_numbers(void) {
   bson_t *expected = parse(numeric_fixture);
   char *error = NULL;
   char *json = cl_document_json(expected, &error);
   assert(json && !error);
   assert(strstr(json, "9007199254740993") && strstr(json, "$numberLong"));
   bson_t *actual = parse(json);
   assert_same_numeric_values(expected, actual);
   bson_destroy(actual);
   bson_destroy(expected);
   bson_free(json);
}

int main(int argc, char **argv) {
   if (argc == 2 && strcmp(argv[1], "--export-browse-fixture") == 0) {
      mongoc_init();
      CLMongoClient *client = bson_malloc0(sizeof *client);
      client->value = mongoc_client_new("mongodb://example.invalid/");
      client->browse_cursor = synthetic_browse_cursor(client->value, 21, 0);
      char *error = NULL;
      char *json = cl_mongo_browse_next(client, &error);
      assert(json && !error && client->browse_pending);
      puts(json);
      bson_free(json);
      cl_mongo_disconnect(client); // closes cursor and lookahead on disconnect
      mongoc_cleanup();
      return 0;
   }

   if (argc == 2 && strcmp(argv[1], "--export-numeric-fixture") == 0) {
      bson_t *value = parse(numeric_fixture);
      char *error = NULL;
      char *json = cl_document_json(value, &error);
      assert(json && !error);
      puts(json);
      bson_free(json);
      bson_destroy(value);
      return 0;
   }
   if (argc == 3 && strcmp(argv[1], "--verify-numeric-fixture") == 0) {
      FILE *file = fopen(argv[2], "rb");
      assert(file);
      char buffer[8192];
      size_t length = fread(buffer, 1, sizeof buffer - 1, file);
      assert(feof(file));
      fclose(file);
      buffer[length] = 0;
      bson_t *expected = parse(numeric_fixture), *actual = parse(buffer);
      assert_same_numeric_values(expected, actual);
      bson_destroy(expected);
      bson_destroy(actual);
      puts("PASS: BSON -> canonical JSON -> Swift formatting -> BSON preserves numeric types and bits");
      return 0;
   }
   mongoc_init();
   test_aggregation_guards();
   test_tls_and_timeout_policy();
   test_document_byte_budget();
   test_total_byte_budget_boundaries();
   test_cursor_is_bounded_without_network();
   test_unsafe_execution_stops_before_client_use();
   test_script_and_collection_guards();
   test_canonical_numbers();
   test_browse_order_and_boundaries();
   test_browse_failure_and_close();
   mongoc_cleanup();
   puts("PASS: 10 native bridge safety groups (synthetic BSON; no network)");
   return 0;
}
