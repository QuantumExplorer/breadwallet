//
//  Created by Andrew Podkovyrin
//  Copyright © 2019 Dash Core Group. All rights reserved.
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

#import "DWDerivationPathKeysModel.h"

#import <DashSync/DSAuthenticationKeysDerivationPath.h>
#import <DashSync/DashSync.h>
#import <DashSync/DSMasternodeManager+LocalMasternode.h>

#import "DWDerivationPathKeysItemObject.h"
#import "DWEnvironment.h"
#import "DWSelectorFormCellModel.h"

NS_ASSUME_NONNULL_BEGIN


#pragma mark -

@interface DWDerivationPathKeysModel ()

@property (readonly, nonatomic, strong) DSAuthenticationKeysDerivationPath *derivationPath;

@end

@implementation DWDerivationPathKeysModel

- (instancetype)initWithDerivationPath:(DSAuthenticationKeysDerivationPath *)derivationPath {
    self = [super init];
    if (self) {
        _derivationPath = derivationPath;

        _loadMoreItem = [[DWSelectorFormCellModel alloc] initWithTitle:NSLocalizedString(@"Load more", nil)];
    }
    return self;
}

- (id<DWDerivationPathKeysItem>)itemForInfo:(DWDerivationPathInfo)info atIndex:(NSInteger)index {
    DSWallet *wallet = [DWEnvironment sharedInstance].currentWallet;

    DWDerivationPathKeysItemObject *item = [[DWDerivationPathKeysItemObject alloc] init];
    switch (info) {
        case DWDerivationPathInfo_Address: {
            item.title = NSLocalizedString(@"Address", nil);
            item.detail = [self.derivationPath addressAtIndex:index];

            break;
        }
        case DWDerivationPathInfo_PublicKey: {
            item.title = NSLocalizedString(@"Public key", nil);
            item.detail = [self.derivationPath publicKeyDataAtIndex:index].hexString;

            break;
        }
        case DWDerivationPathInfo_PrivateKey: {
            item.title = NSLocalizedString(@"Private key", nil);
            @autoreleasepool {
                NSData *seed = [[DSBIP39Mnemonic sharedInstance] deriveKeyFromPhrase:wallet.seedPhraseIfAuthenticated
                                                                      withPassphrase:nil];
                DSKey *key = [self.derivationPath privateKeyAtIndex:index fromSeed:seed];
                item.detail = key.secretKeyString;
            }

            break;
        }
        case DWDerivationPathInfo_WIFPrivateKey: {
            item.title = NSLocalizedString(@"WIF Private key", nil);
            @autoreleasepool {
                NSData *seed = [[DSBIP39Mnemonic sharedInstance] deriveKeyFromPhrase:wallet.seedPhraseIfAuthenticated
                                                                      withPassphrase:nil];
                DSKey *key = [self.derivationPath privateKeyAtIndex:index fromSeed:seed];
                item.detail = [key serializedPrivateKeyForChain:wallet.chain];
            }

            break;
        }
        case DWDerivationPathInfo_MasternodeInfo: {
            BOOL used = [self.derivationPath addressIsUsedAtIndex:index];
            if (used) {
                DSLocalMasternode *localMasternode = [self.derivationPath.chain.chainManager.masternodeManager localMasternodeUsingIndex:index atDerivationPath:self.derivationPath];
                if (localMasternode) {
                    item.title = NSLocalizedString(@"Used at IP address", nil);
                    item.detail = localMasternode.ipAddressAndIfNonstandardPortString;
                }
                else {
                    NSArray *localMasternodesArray = [self.derivationPath.chain.chainManager.masternodeManager localMasternodesPreviouslyUsingIndex:index atDerivationPath:self.derivationPath];
                    if (localMasternodesArray.count == 1) {
                        item.title = NSLocalizedString(@"Previously used at IP address", nil);
                        localMasternode = [localMasternodesArray firstObject];
                        item.detail = localMasternode.ipAddressAndIfNonstandardPortString;
                    }
                    else if (localMasternodesArray.count == 0) {
                        item.title = NSLocalizedString(@"Used", nil);
                        item.detail = @"";
                    }
                    else {
                        item.title = NSLocalizedString(@"Previously used at IP address", nil);
                        localMasternode = [localMasternodesArray lastObject];
                        item.detail = localMasternode.ipAddressAndIfNonstandardPortString;
                    }
                }
            }
            else {
                item.title = NSLocalizedString(@"Not yet used", nil);
                item.detail = @"";
            }


            break;
        }
        default: {
            NSAssert(NO, @"Inconsistent state");

            break;
        }
    }

    return item;
}

@end

NS_ASSUME_NONNULL_END
