//
//  Created by Andrew Podkovyrin
//  Copyright © 2020 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DWUserSearchModel.h"

#import "DWDPSearchItemsFactory.h"
#import "DWDashPayConstants.h"
#import "DWDashPayContactsActions.h"
#import "DWEnvironment.h"

NS_ASSUME_NONNULL_BEGIN

@interface DWUserSearchRequest : NSObject

@property (readonly, nonatomic, copy) NSString *trimmedQuery;
@property (nonatomic, strong) NSData * startAfterIdentityId;
@property (nullable, nonatomic, copy) NSArray<id<DWDPBasicUserItem, DWDPBlockchainIdentityBackedItem>> *items;
@property (nonatomic, assign) BOOL requestInProgress;
@property (nonatomic, assign) BOOL hasNextPage;

@end

NS_ASSUME_NONNULL_END

@implementation DWUserSearchRequest

- (instancetype)initWithTrimmedQuery:(NSString *)trimmedQuery {
    self = [super init];
    if (self) {
        _trimmedQuery = [trimmedQuery copy];
        _startAfterIdentityId = nil;
    }
    return self;
}

@end

#pragma mark - Model

NS_ASSUME_NONNULL_BEGIN

static uint32_t const LIMIT = 100;
static NSTimeInterval SEARCH_DEBOUNCE_DELAY = 0.4;

@interface DWUserSearchModel ()

@property (nullable, nonatomic, strong) DWUserSearchRequest *searchRequest;
@property (nullable, nonatomic, strong) id<DSDAPINetworkServiceRequest> request;
@property (readonly, nonatomic, strong) DWDPSearchItemsFactory *itemsFactory;

@end

NS_ASSUME_NONNULL_END

@implementation DWUserSearchModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _itemsFactory = [[DWDPSearchItemsFactory alloc] init];
    }
    return self;
}

- (NSString *)trimmedQuery {
    return self.searchRequest.trimmedQuery ?: @"";
}

- (void)searchWithQuery:(NSString *)searchQuery {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performInitialSearch) object:nil];

    [self.request cancel];
    self.request = nil;

    self.searchRequest = nil;

    NSCharacterSet *whitespaces = [NSCharacterSet whitespaceCharacterSet];
    NSString *trimmedQuery = [searchQuery stringByTrimmingCharactersInSet:whitespaces] ?: @"";
    if ([self.searchRequest.trimmedQuery isEqualToString:trimmedQuery]) {
        return;
    }
    if (trimmedQuery.length < DW_MIN_USERNAME_LENGTH) {
        return;
    }

    self.searchRequest = [[DWUserSearchRequest alloc] initWithTrimmedQuery:trimmedQuery];

    [self performSelector:@selector(performInitialSearch) withObject:nil afterDelay:SEARCH_DEBOUNCE_DELAY];
}

- (void)willDisplayItemAtIndex:(NSInteger)index {
    const BOOL shouldRequestNextPage = self.searchRequest.items.count >= LIMIT && index >= self.searchRequest.items.count - LIMIT / 4;
    if (shouldRequestNextPage && self.searchRequest.hasNextPage && !self.searchRequest.requestInProgress) {
        id<DWDPBasicUserItem, DWDPBlockchainIdentityBackedItem> lastObject = self.searchRequest.items.lastObject;
        self.searchRequest.startAfterIdentityId = uint256_data(lastObject.blockchainIdentity.uniqueID);
        [self performSearchAndNotify:NO];
    }
}

- (id<DWDPBasicUserItem>)itemAtIndex:(NSInteger)index {
    if (index < 0 || self.searchRequest.items.count < index) {
        NSAssert(NO, @"No blockchain identity for invalid index %ld", index);
        return nil;
    }

    return self.searchRequest.items[index];
}

- (BOOL)canOpenBlockchainIdentity:(DSBlockchainIdentity *)blockchainIdentity {
    DSWallet *wallet = [DWEnvironment sharedInstance].currentWallet;
    DSBlockchainIdentity *myBlockchainIdentity = wallet.defaultBlockchainIdentity;
    return !uint256_eq(myBlockchainIdentity.uniqueID, blockchainIdentity.uniqueID);
}

- (void)acceptContactRequest:(id<DWDPBasicUserItem>)item {
    __weak typeof(self) weakSelf = self;
    [DWDashPayContactsActions
        acceptContactRequest:item
                  completion:^(BOOL success, NSArray<NSError *> *_Nonnull errors) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (!strongSelf) {
                          return;
                      }

                      // TODO: DP update state more gently
                      [strongSelf performSearchAndNotify:YES];
                  }];
}

- (void)declineContactRequest:(id<DWDPBasicUserItem>)item {
    [DWDashPayContactsActions declineContactRequest:item completion:nil];
}

#pragma mark Private

- (void)performInitialSearch {
    [self performSearchAndNotify:YES];
}

- (void)performSearchAndNotify:(BOOL)notify {
    if (notify) {
        [self.delegate userSearchModelDidStartSearch:self];
    }

    if (self.searchRequest) {
        [self performSearchWithQuery:self.searchRequest.trimmedQuery startAfter:self.searchRequest.startAfterIdentityId];
    }
}

- (void)performSearchWithQuery:(NSString *)query startAfter:(NSData*)startAfter {
    self.searchRequest.requestInProgress = YES;

    DSIdentitiesManager *manager = [DWEnvironment sharedInstance].currentChainManager.identitiesManager;
    __weak typeof(self) weakSelf = self;
    self.request = [manager
        searchIdentitiesByNamePrefix:query
                            inDomain:@"dash"
                          startAfter:startAfter
                               limit:LIMIT
                      withCompletion:^(BOOL success, NSArray<DSBlockchainIdentity *> *_Nullable blockchainIdentities, NSArray<NSError *> *errors) {
                          __strong typeof(weakSelf) strongSelf = weakSelf;
                          if (!strongSelf) {
                              return;
                          }

                          NSAssert([NSThread isMainThread], @"Main thread is assumed here");

                          // search query was changed before results arrive, ignore results
                          if (!strongSelf.searchRequest || ![strongSelf.searchRequest.trimmedQuery isEqualToString:query]) {
                              return;
                          }

                          strongSelf.searchRequest.requestInProgress = NO;

                          if (success) {
                              NSMutableArray<id<DWDPBasicUserItem, DWDPBlockchainIdentityBackedItem>> *items = strongSelf.searchRequest.items ? [strongSelf.searchRequest.items mutableCopy] : [NSMutableArray array];
                              for (DSBlockchainIdentity *blockchainIdentity in blockchainIdentities) {
                                  id<DWDPBasicUserItem, DWDPBlockchainIdentityBackedItem> item = [strongSelf.itemsFactory itemForBlockchainIdentity:blockchainIdentity];
                                  [items addObject:item];
                              }

                              strongSelf.searchRequest.hasNextPage = blockchainIdentities.count >= LIMIT;
                              strongSelf.searchRequest.items = items;
                              [strongSelf.delegate userSearchModel:strongSelf completedWithItems:items];
                          }
                          else {
                              strongSelf.searchRequest.hasNextPage = NO;
                              [strongSelf.delegate userSearchModel:strongSelf completedWithError:errors.firstObject];
                          }
                      }];
}

@end
