
#include "../sketchybar/helpers/event_providers/sketchybar.h"
static char sent[4096];
static void capture(const char* s) { snprintf(sent, sizeof(sent), "%s", s); }
#define sketchybar capture
#define main provider_main
#include "../sketchybar/helpers/event_providers/brew_check/brew_check.c"
#undef main
int main(int argc, char** argv) {
 if (argc != 2) return 2;
 brew_t b; if(brew_init(&b)!=BREW_SUCCESS) return 2;
 snprintf(BREW_EXECUTABLE_PATH,sizeof(BREW_EXECUTABLE_PATH),"%s",argv[1]);
 b.last_update=time(NULL); b.outdated_count=7; strcpy(b.package_list,"old-package");
 check_and_notify(&b,"audit",3600,false,false);
 printf("periodic_count=%d expected=0 event=%s\n",b.outdated_count,sent);
 int stale=b.outdated_count!=0;
 check_and_notify(&b,"audit",3600,true,false);
 printf("forced_count=%d expected=0\n",b.outdated_count);
 const char* args[]={"/bin/sh","-c","printf 'actual-package\\n'; printf 'Warning: diagnostic only\\n' >&2",NULL};
 char* out=NULL; size_t size=0;
 if(_brew_execute_command(args,&out,&size)!=BREW_SUCCESS) return 3;
 if(_brew_parse_outdated_output(&b,out)!=BREW_SUCCESS) return 4;
 printf("parsed_count=%d expected=1 packages=%s\n",b.outdated_count,b.package_list);
 int contaminated=b.outdated_count!=1; free(out); brew_cleanup(&b);
 return stale||contaminated ? 1:0;
}
