#ifndef ClusterLens_MongoBridge_h
#define ClusterLens_MongoBridge_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *CLMongoClientRef;

CLMongoClientRef cl_mongo_connect(const char *uri,
                                  const char *ca_file,
                                  char **error_message);
void cl_mongo_disconnect(CLMongoClientRef client);

char *cl_mongo_list_databases(CLMongoClientRef client, char **error_message);
char *cl_mongo_list_collections(CLMongoClientRef client,
                                const char *database,
                                char **error_message);
char *cl_mongo_execute(CLMongoClientRef client,
                       const char *database,
                       const char *collection,
                       const char *operation,
                       const char *input_json,
                       char **error_message);

// One read-only browsing cursor per client, owned by the Swift client actor.
char *cl_mongo_browse_start(CLMongoClientRef client, const char *database,
                           const char *collection, char **error_message);
char *cl_mongo_browse_filtered(CLMongoClientRef client, const char *database,
                              const char *collection, const char *query_json, char **error_message);
char *cl_mongo_browse_next(CLMongoClientRef client, char **error_message);
void cl_mongo_browse_close(CLMongoClientRef client);

void cl_mongo_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
