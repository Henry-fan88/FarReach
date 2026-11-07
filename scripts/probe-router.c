// Read-only gateway discovery: protocol and all port/TTL fields are zero.
// This never requests or removes a port mapping.
#include <dns_sd.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>
#include <time.h>
static int answered=0;
static void reply(DNSServiceRef ref,DNSServiceFlags flags,uint32_t interfaceIndex,DNSServiceErrorType error,uint32_t address,DNSServiceProtocol protocol,uint16_t internal,uint16_t external,uint32_t ttl,void *context){
    char ip[INET_ADDRSTRLEN]; inet_ntop(AF_INET,&address,ip,sizeof(ip));
    printf("{\"error\":%d,\"interface\":%u,\"external_ipv4\":\"%s\",\"mapping_requested\":false}\n",error,interfaceIndex,ip);fflush(stdout);if(address!=0 || error!=0)answered=1;
}
int main(void){
    DNSServiceRef ref=NULL;
    int error=DNSServiceNATPortMappingCreate(&ref,0,0,0,0,0,0,reply,NULL);
    if(error){printf("{\"start_error\":%d,\"mapping_requested\":false}\n",error);return 1;}
    int fd=DNSServiceRefSockFD(ref);time_t end=time(NULL)+15;
    while(!answered&&time(NULL)<end){fd_set fds;FD_ZERO(&fds);FD_SET(fd,&fds);struct timeval tv={1,0};if(select(fd+1,&fds,NULL,NULL,&tv)>0){error=DNSServiceProcessResult(ref);if(error){printf("{\"process_error\":%d}\n",error);break;}}}
    if(!answered)puts("{\"result\":\"no_gateway_response_within_15_seconds\",\"mapping_requested\":false}");
    DNSServiceRefDeallocate(ref);return answered?0:2;
}
