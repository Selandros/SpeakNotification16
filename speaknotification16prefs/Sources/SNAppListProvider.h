#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

NSArray<NSDictionary *> *SNVisibleAppList(void);
NSArray<NSDictionary *> *SNVisibleAppListForceRefresh(void);

#ifdef __cplusplus
}
#endif
