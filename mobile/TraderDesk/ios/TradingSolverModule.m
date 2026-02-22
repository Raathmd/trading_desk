// TradingSolverModule.m — Objective-C bridge to expose TradingSolverModule to React Native

#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(TradingSolver, NSObject)

RCT_EXTERN_METHOD(solve:(NSString *)descriptorBase64
                  variables:(NSArray<NSNumber *> *)variablesArray
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(monteCarlo:(NSString *)descriptorBase64
                  centerVariables:(NSArray<NSNumber *> *)centerVariables
                  nScenarios:(NSInteger)nScenarios
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getVersion:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

@end
