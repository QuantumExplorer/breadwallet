//
//  BRWalletManager.m
//  BreadWallet
//
//  Created by Aaron Voisine on 3/2/14.
//  Copyright (c) 2014 Aaron Voisine <voisine@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "BRWalletManager.h"
#import "BRKey.h"
#import "BRKey+BIP38.h"
#import "BRBIP39Mnemonic.h"
#import "BRBIP32Sequence.h"
#import "BRTransaction.h"
#import "BRTransactionEntity.h"
#import "BRTxMetadataEntity.h"
#import "BRAddressEntity.h"
#import "BREventManager.h"
#import "NSString+Bitcoin.h"
#import "NSData+Bitcoin.h"
#import "NSMutableData+Bitcoin.h"
#import "NSManagedObject+Sugar.h"
#import "NSAttributedString+Attachments.h"
#import "NSString+Dash.h"
#import "Reachability.h"
#import <LocalAuthentication/LocalAuthentication.h>

#define CIRCLE  @"\xE2\x97\x8C" // dotted circle (utf-8)
#define DOT     @"\xE2\x97\x8F" // black circle (utf-8)

#define UNSPENT_URL          @"http://insight.dash.org/insight-api-dash/addrs/utxo"
#define UNSPENT_FAILOVER_URL @"https://insight.dash.siampm.com/api/addrs/utxo"
#define FEE_PER_KB_URL       0 //not supported @"https://api.breadwallet.com/fee-per-kb"
#define BITCOIN_TICKER_URL  @"https://bitpay.com/rates"
#define POLONIEX_TICKER_URL  @"https://poloniex.com/public?command=returnOrderBook&currencyPair=BTC_DASH&depth=1"
#define DASHCENTRAL_TICKER_URL  @"https://www.dashcentral.org/api/v1/public"
#define TICKER_REFRESH_TIME 60.0

#define SEED_ENTROPY_LENGTH   (128/8)
#define SEC_ATTR_SERVICE      @"org.paccoin.wallet"
#define DEFAULT_CURRENCY_CODE @"USD"
#define DEFAULT_SPENT_LIMIT   DUFFS

#define LOCAL_CURRENCY_CODE_KEY @"LOCAL_CURRENCY_CODE"
#define CURRENCY_CODES_KEY      @"CURRENCY_CODES"
#define CURRENCY_NAMES_KEY      @"CURRENCY_NAMES"
#define CURRENCY_PRICES_KEY     @"CURRENCY_PRICES"
#define POLONIEX_DASH_BTC_PRICE_KEY  @"POLONIEX_DASH_BTC_PRICE"
#define POLONIEX_DASH_BTC_UPDATE_TIME_KEY  @"POLONIEX_DASH_BTC_UPDATE_TIME"
#define DASHCENTRAL_DASH_BTC_PRICE_KEY @"DASHCENTRAL_DASH_BTC_PRICE"
#define DASHCENTRAL_DASH_BTC_UPDATE_TIME_KEY @"DASHCENTRAL_DASH_BTC_UPDATE_TIME"
#define SPEND_LIMIT_AMOUNT_KEY  @"SPEND_LIMIT_AMOUNT"
#define SECURE_TIME_KEY         @"SECURE_TIME"
#define FEE_PER_KB_KEY          @"FEE_PER_KB"

#define MNEMONIC_KEY        @"mnemonic"
#define CREATION_TIME_KEY   @"creationtime"
#define MASTER_PUBKEY_KEY_BIP44   @"masterpubkeyBIP44" //these are old and need to be retired
#define MASTER_PUBKEY_KEY_BIP32   @"masterpubkeyBIP32" //these are old and need to be retired
#define EXTENDED_0_PUBKEY_KEY_BIP44   @"extended0pubkeyBIP44"
#define EXTENDED_0_PUBKEY_KEY_BIP32   @"extended0pubkeyBIP32"
#define SPEND_LIMIT_KEY     @"spendlimit"
#define PIN_KEY             @"pin"
#define PIN_FAIL_COUNT_KEY  @"pinfailcount"
#define PIN_FAIL_HEIGHT_KEY @"pinfailheight"
#define AUTH_PRIVKEY_KEY    @"authprivkey"
#define USER_ACCOUNT_KEY    @"https://api.dashwallet.com"

static BOOL setKeychainData(NSData *data, NSString *key, BOOL authenticated)
{
    if (! key) return NO;
    
    id accessible = (authenticated) ? (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    : (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                            (__bridge id)kSecAttrAccount:key};
    
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL) == errSecItemNotFound) {
        if (! data) return YES;
        
        NSDictionary *item = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                               (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                               (__bridge id)kSecAttrAccount:key,
                               (__bridge id)kSecAttrAccessible:accessible,
                               (__bridge id)kSecValueData:data};
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        
        if (status == noErr) return YES;
        NSLog(@"SecItemAdd error: %@",
              [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil].localizedDescription);
        return NO;
    }
    
    if (! data) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        
        if (status == noErr) return YES;
        NSLog(@"SecItemDelete error: %@",
              [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil].localizedDescription);
        return NO;
    }
    
    NSDictionary *update = @{(__bridge id)kSecAttrAccessible:accessible,
                             (__bridge id)kSecValueData:data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    
    if (status == noErr) return YES;
    NSLog(@"SecItemUpdate error: %@",
          [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil].localizedDescription);
    return NO;
}

static NSData *getKeychainData(NSString *key, NSError **error)
{
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService:SEC_ATTR_SERVICE,
                            (__bridge id)kSecAttrAccount:key,
                            (__bridge id)kSecReturnData:@YES};
    CFDataRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    
    if (status == errSecItemNotFound) return nil;
    if (status == noErr) return CFBridgingRelease(result);
    NSLog(@"SecItemCopyMatching error: %@",
          [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil].localizedDescription);
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return nil;
}

static BOOL setKeychainInt(int64_t i, NSString *key, BOOL authenticated)
{
    @autoreleasepool {
        NSMutableData *d = [NSMutableData secureDataWithLength:sizeof(int64_t)];
        
        *(int64_t *)d.mutableBytes = i;
        return setKeychainData(d, key, authenticated);
    }
}

static int64_t getKeychainInt(NSString *key, NSError **error)
{
    @autoreleasepool {
        NSData *d = getKeychainData(key, error);
        
        return (d.length == sizeof(int64_t)) ? *(int64_t *)d.bytes : 0;
    }
}

static BOOL setKeychainString(NSString *s, NSString *key, BOOL authenticated)
{
    @autoreleasepool {
        NSData *d = (s) ? CFBridgingRelease(CFStringCreateExternalRepresentation(SecureAllocator(), (CFStringRef)s,
                                                                                 kCFStringEncodingUTF8, 0)) : nil;
        
        return setKeychainData(d, key, authenticated);
    }
}

static NSString *getKeychainString(NSString *key, NSError **error)
{
    @autoreleasepool {
        NSData *d = getKeychainData(key, error);
        
        return (d) ? CFBridgingRelease(CFStringCreateFromExternalRepresentation(SecureAllocator(), (CFDataRef)d,
                                                                                kCFStringEncodingUTF8)) : nil;
    }
}

static BOOL setKeychainDict(NSDictionary *dict, NSString *key, BOOL authenticated)
{
    @autoreleasepool {
        NSData *d = (dict) ? [NSKeyedArchiver archivedDataWithRootObject:dict] : nil;
        
        return setKeychainData(d, key, authenticated);
    }
}

static NSDictionary *getKeychainDict(NSString *key, NSError **error)
{
    @autoreleasepool {
        NSData *d = getKeychainData(key, error);
        
        return (d) ? [NSKeyedUnarchiver unarchiveObjectWithData:d] : nil;
    }
}

typedef BOOL (^PinVerificationBlock)(NSString * _Nonnull currentPin,BRWalletManager * context);

@interface BRWalletManager()

@property (nonatomic, strong) BRWallet *wallet;
@property (nonatomic, strong) Reachability *reachability;
@property (nonatomic, strong) NSArray *currencyPrices;
@property (nonatomic, assign) BOOL sweepFee;
@property (nonatomic, strong) NSString *sweepKey;
@property (nonatomic, strong) void (^sweepCompletion)(BRTransaction *tx, uint64_t fee, NSError *error);
@property (nonatomic, strong) UIAlertController *pinAlertController;
@property (nonatomic, strong) UIAlertController *resetAlertController;
@property (nonatomic, strong) UITextField *pinField;
@property (nonatomic, strong) NSMutableSet *failedPins;
@property (nonatomic, strong) id protectedObserver, keyboardObserver;
@property (nonatomic, copy) PinVerificationBlock pinVerificationBlock;

@property (nonatomic, strong) NSNumber * _Nullable bitcoinDashPrice; // exchange rate in bitcoin per dash
@property (nonatomic, strong) NSNumber * _Nullable localCurrencyBitcoinPrice; // exchange rate in local currency units per bitcoin
@property (nonatomic, strong) NSNumber * _Nullable localCurrencyDashPrice;

@end

@implementation BRWalletManager

+ (instancetype)sharedInstance
{
    static id singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        singleton = [self new];
    });
    
    return singleton;
}

- (instancetype)init
{
    if (! (self = [super init])) return nil;
    
    [NSManagedObject setConcurrencyType:NSPrivateQueueConcurrencyType];
    self.sequence = [BRBIP32Sequence new];
    self.mnemonic = [BRBIP39Mnemonic new];
    self.reachability = [Reachability reachabilityForInternetConnection];
    self.failedPins = [NSMutableSet set];
    _dashFormat = [NSNumberFormatter new];
    self.dashFormat.lenient = YES;
    self.dashFormat.numberStyle = NSNumberFormatterCurrencyStyle;
    self.dashFormat.generatesDecimalNumbers = YES;
    self.dashFormat.negativeFormat = [self.dashFormat.positiveFormat
                                      stringByReplacingCharactersInRange:[self.dashFormat.positiveFormat rangeOfString:@"#"]
                                      withString:@"-#"];
    self.dashFormat.currencyCode = @"DASH";
    self.dashFormat.currencySymbol = DASH NARROW_NBSP;
    self.dashFormat.maximumFractionDigits = 8;
    self.dashFormat.minimumFractionDigits = 0; // iOS 8 bug, minimumFractionDigits now has to be set after currencySymbol
    self.dashFormat.maximum = @(MAX_MONEY/(int64_t)pow(10.0, self.dashFormat.maximumFractionDigits));
    
    _dashSignificantFormat = [NSNumberFormatter new];
    self.dashSignificantFormat.lenient = YES;
    self.dashSignificantFormat.numberStyle = NSNumberFormatterCurrencyStyle;
    self.dashSignificantFormat.generatesDecimalNumbers = YES;
    self.dashSignificantFormat.negativeFormat = [self.dashFormat.positiveFormat
                                                 stringByReplacingCharactersInRange:[self.dashFormat.positiveFormat rangeOfString:@"#"]
                                                 withString:@"-#"];
    self.dashSignificantFormat.currencyCode = @"DASH";
    self.dashSignificantFormat.currencySymbol = DASH NARROW_NBSP;
    self.dashSignificantFormat.usesSignificantDigits = TRUE;
    self.dashSignificantFormat.minimumSignificantDigits = 1;
    self.dashSignificantFormat.maximumSignificantDigits = 6;
    self.dashSignificantFormat.maximumFractionDigits = 8;
    self.dashSignificantFormat.minimumFractionDigits = 0; // iOS 8 bug, minimumFractionDigits now has to be set after currencySymbol
    self.dashSignificantFormat.maximum = @(MAX_MONEY/(int64_t)pow(10.0, self.dashFormat.maximumFractionDigits));
    
    _bitcoinFormat = [NSNumberFormatter new];
    self.bitcoinFormat.lenient = YES;
    self.bitcoinFormat.numberStyle = NSNumberFormatterCurrencyStyle;
    self.bitcoinFormat.generatesDecimalNumbers = YES;
    self.bitcoinFormat.negativeFormat = [self.bitcoinFormat.positiveFormat
                                         stringByReplacingCharactersInRange:[self.bitcoinFormat.positiveFormat rangeOfString:@"#"]
                                         withString:@"-#"];
    self.bitcoinFormat.currencyCode = @"BTC";
    self.bitcoinFormat.currencySymbol = BTC NARROW_NBSP;
    self.bitcoinFormat.maximumFractionDigits = 8;
    self.bitcoinFormat.minimumFractionDigits = 0; // iOS 8 bug, minimumFractionDigits now has to be set after currencySymbol
    self.bitcoinFormat.maximum = @(MAX_MONEY/(int64_t)pow(10.0, self.bitcoinFormat.maximumFractionDigits));
    
    _unknownFormat = [NSNumberFormatter new];
    self.unknownFormat.lenient = YES;
    self.unknownFormat.numberStyle = NSNumberFormatterDecimalStyle;
    self.unknownFormat.generatesDecimalNumbers = YES;
    self.unknownFormat.negativeFormat = [self.unknownFormat.positiveFormat
                                         stringByReplacingCharactersInRange:[self.unknownFormat.positiveFormat rangeOfString:@"#"]
                                         withString:@"-#"];
    self.unknownFormat.maximumFractionDigits = 8;
    self.unknownFormat.minimumFractionDigits = 0; // iOS 8 bug, minimumFractionDigits now has to be set after currencySymbol
    
    _localFormat = [NSNumberFormatter new];
    self.localFormat.lenient = YES;
    self.localFormat.numberStyle = NSNumberFormatterCurrencyStyle;
    self.localFormat.generatesDecimalNumbers = YES;
    self.localFormat.negativeFormat = self.dashFormat.negativeFormat;
    
    self.protectedObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationProtectedDataDidBecomeAvailable object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           [self protectedInit];
                                                       }];
    self.keyboardObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        if ([self pinAlertControllerIsVisible]) {
            CGFloat alertHeight = self.pinAlertController.view.frame.size.height;
            CGFloat keyboardHeight = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
            CGFloat difference = ([UIScreen mainScreen].bounds.size.height + alertHeight)/2.0 - ([UIScreen mainScreen].bounds.size.height - keyboardHeight) + 20;
            if (difference > 0) {
                [UIView animateWithDuration:0.2 animations:^{
                    self.pinAlertController.view.superview.center = CGPointMake([UIScreen mainScreen].bounds.size.width/2.0, [UIScreen mainScreen].bounds.size.height/2.0 - difference);
                }];
            }
        }
    }];
    if ([UIApplication sharedApplication].protectedDataAvailable) [self protectedInit];
    return self;
}

- (void)protectedInit
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    
    if (self.protectedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.protectedObserver];
    self.protectedObserver = nil;
    _currencyCodes = [defs arrayForKey:CURRENCY_CODES_KEY];
    _currencyNames = [defs arrayForKey:CURRENCY_NAMES_KEY];
    _currencyPrices = [defs arrayForKey:CURRENCY_PRICES_KEY];
    self.localCurrencyCode = ([defs stringForKey:LOCAL_CURRENCY_CODE_KEY]) ?
    [defs stringForKey:LOCAL_CURRENCY_CODE_KEY] : [[NSLocale currentLocale] objectForKey:NSLocaleCurrencyCode];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBitcoinExchangeRate];
        [self updateDashExchangeRate];
        [self updateDashCentralExchangeRateFallback];
    });
}

- (void)dealloc
{
    if (self.protectedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.protectedObserver];
    if (self.keyboardObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.keyboardObserver];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (BRWallet *)wallet
{
    if (_wallet) return _wallet;
    
    uint64_t feePerKb = 0;
    NSData *mpk = self.extendedBIP44PublicKey;
    
    if (! mpk) return _wallet;
    
    NSData *mpkBIP32 = self.extendedBIP32PublicKey;
    
    if (! mpkBIP32) return _wallet;
    
    @synchronized(self) {
        if (_wallet) return _wallet;
        
        _wallet = [[BRWallet alloc] initWithContext:[NSManagedObject context] sequence:self.sequence
                               masterBIP44PublicKey:mpk masterBIP32PublicKey:mpkBIP32 requestSeedBlock:^void(NSString *authprompt, uint64_t amount, SeedCompletionBlock seedCompletion) {
                                   //this happens when we request the seed
                                   [self seedWithPrompt:authprompt forAmount:amount completion:seedCompletion];
                               }];
        
        _wallet.feePerKb = DEFAULT_FEE_PER_KB;
        feePerKb = [[NSUserDefaults standardUserDefaults] doubleForKey:FEE_PER_KB_KEY];
        if (feePerKb >= MIN_FEE_PER_KB && feePerKb <= MAX_FEE_PER_KB) _wallet.feePerKb = feePerKb;
        
        // verify that keychain matches core data, with different access and backup policies it's possible to diverge
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BRKey *k = [BRKey keyWithPublicKey:[self.sequence publicKey:0 internal:NO masterPublicKey:mpk]];
            
            if (_wallet.allReceiveAddresses.count > 0 && k && ! [_wallet containsAddress:k.address]) {
                NSLog(@"wallet doesn't contain address: %@", k.address);
#if 0
                abort(); // don't wipe core data for debug builds
#else
                [[NSManagedObject context] performBlockAndWait:^{
                    [BRAddressEntity deleteObjects:[BRAddressEntity allObjects]];
                    [BRTransactionEntity deleteObjects:[BRTransactionEntity allObjects]];
                    [BRTxMetadataEntity deleteObjects:[BRTxMetadataEntity allObjects]];
                    [NSManagedObject saveContext];
                }];
                
                _wallet = nil;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletManagerSeedChangedNotification
                                                                        object:nil];
                    [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletBalanceChangedNotification
                                                                        object:nil];
                });
#endif
            }
        });
        
        return _wallet;
    }
}

// true if keychain is available and we know that no wallet exists on it
- (BOOL)noWallet
{
    NSError *error = nil;
    if (_wallet) return NO;
    if (getKeychainData(EXTENDED_0_PUBKEY_KEY_BIP44, &error) || error) return NO;
    if (getKeychainData(EXTENDED_0_PUBKEY_KEY_BIP32, &error) || error) return NO;
    return YES;
}

- (BOOL)noOldWallet
{
    NSError *error = nil;
    if (_wallet) return NO;
    if (getKeychainData(MASTER_PUBKEY_KEY_BIP44, &error) || error) return NO;
    if (getKeychainData(MASTER_PUBKEY_KEY_BIP32, &error) || error) return NO;
    return YES;
}

//there was an issue with extended public keys on version 0.7.6 and before, this fixes that
-(void)upgradeExtendedKeysWithCompletion:(UpgradeCompletionBlock)completion;
{
    NSError * error = nil;
    NSData * data = getKeychainData(EXTENDED_0_PUBKEY_KEY_BIP44, &error);
    if (error) {
        completion(NO,NO,NO,NO);
        return;
    }
    NSData * oldData = (data)?nil:getKeychainData(MASTER_PUBKEY_KEY_BIP44, nil);
    if (!data && oldData) {
        NSLog(@"fixing public key");
        //upgrade scenario
        [self authenticateWithPrompt:(NSLocalizedString(@"please enter pin to upgrade wallet", nil)) andTouchId:NO alertIfLockout:NO completion:^(BOOL authenticated,BOOL cancelled) {
            if (!authenticated) {
                completion(NO,YES,NO,cancelled);
                return;
            }
            @autoreleasepool {
                NSString * seedPhrase = authenticated?getKeychainString(MNEMONIC_KEY, nil):nil;
                if (!seedPhrase) {
                    completion(NO,YES,YES,NO);
                    return;
                }
                NSData * derivedKeyData = (seedPhrase) ?[self.mnemonic
                                                         deriveKeyFromPhrase:seedPhrase withPassphrase:nil]:nil;
                
                NSData *masterPubKeyBIP44 = (seedPhrase) ? [self.sequence extendedPublicKeyForAccount:0 fromSeed:derivedKeyData purpose:BIP44_PURPOSE] : nil;
                NSData *masterPubKeyBIP32 = (seedPhrase) ? [self.sequence extendedPublicKeyForAccount:0 fromSeed:derivedKeyData purpose:BIP32_PURPOSE] : nil;
                BOOL failed = !setKeychainData(masterPubKeyBIP44, EXTENDED_0_PUBKEY_KEY_BIP44, NO); //new keys
                failed = failed | !setKeychainData(masterPubKeyBIP32, EXTENDED_0_PUBKEY_KEY_BIP32, NO); //new keys
                failed = failed | !setKeychainData(nil, MASTER_PUBKEY_KEY_BIP44, NO); //old keys
                failed = failed | !setKeychainData(nil, MASTER_PUBKEY_KEY_BIP32, NO); //old keys
                completion(!failed,YES,YES,NO);
                
            }
        }];
        
    } else {
        completion(YES,NO,NO,NO);
    }
}

// true if this is a "watch only" wallet with no signing ability
- (BOOL)watchOnly
{
    return (self.extendedBIP44PublicKey && self.extendedBIP44PublicKey.length == 0) ? YES : NO;
}

// master public key used to generate wallet addresses m/44'/5'/0'
- (NSData *)extendedBIP44PublicKey
{
    return getKeychainData(EXTENDED_0_PUBKEY_KEY_BIP44, nil);
    
}

// master public key using old non BIP 43/44 m/0'
- (NSData *)extendedBIP32PublicKey
{
    return getKeychainData(EXTENDED_0_PUBKEY_KEY_BIP32, nil);
}


- (void)seedPhraseAfterAuthentication:(void (^)(NSString * _Nullable))completion
{
    [self seedPhraseWithPrompt:nil completion:completion];
}

- (void)setSeedPhrase:(NSString *)seedPhrase
{
    @autoreleasepool { // @autoreleasepool ensures sensitive data will be dealocated immediately
        if (seedPhrase) seedPhrase = [self.mnemonic normalizePhrase:seedPhrase];
        
        [[NSManagedObject context] performBlockAndWait:^{
            [BRAddressEntity deleteObjects:[BRAddressEntity allObjects]];
            [BRTransactionEntity deleteObjects:[BRTransactionEntity allObjects]];
            [BRTxMetadataEntity deleteObjects:[BRTxMetadataEntity allObjects]];
            [NSManagedObject saveContext];
        }];
        
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:PIN_UNLOCK_TIME_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        setKeychainData(nil, CREATION_TIME_KEY, NO);
        setKeychainData(nil, EXTENDED_0_PUBKEY_KEY_BIP44, NO);
        setKeychainData(nil, EXTENDED_0_PUBKEY_KEY_BIP32, NO);
        setKeychainData(nil, MASTER_PUBKEY_KEY_BIP32, NO); //for sanity
        setKeychainData(nil, MASTER_PUBKEY_KEY_BIP44, NO); //for sanity
        setKeychainData(nil, SPEND_LIMIT_KEY, NO);
        setKeychainData(nil, PIN_KEY, NO);
        setKeychainData(nil, PIN_FAIL_COUNT_KEY, NO);
        setKeychainData(nil, PIN_FAIL_HEIGHT_KEY, NO);
        setKeychainData(nil, AUTH_PRIVKEY_KEY, NO);
        
        if (! setKeychainString(seedPhrase, MNEMONIC_KEY, YES)) {
            NSLog(@"error setting wallet seed");
            
            if (seedPhrase) {
                UIAlertController * alert = [UIAlertController
                                             alertControllerWithTitle:@"couldn't create wallet"
                                             message:@"error adding master private key to iOS keychain, make sure app has keychain entitlements"
                                             preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                           actionWithTitle:@"abort"
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               exit(0);
                                           }];
                [alert addAction:okButton];
                [self presentAlertController:alert animated:YES completion:nil];
            }
            
            return;
        }
        
        NSData * derivedKeyData = (seedPhrase) ?[self.mnemonic
                                                 deriveKeyFromPhrase:seedPhrase withPassphrase:nil]:nil;
        
        NSData *masterPubKeyBIP44 = (seedPhrase) ? [self.sequence extendedPublicKeyForAccount:0 fromSeed:derivedKeyData purpose:BIP44_PURPOSE] : nil;
        NSData *masterPubKeyBIP32 = (seedPhrase) ? [self.sequence extendedPublicKeyForAccount:0 fromSeed:derivedKeyData purpose:BIP32_PURPOSE] : nil;
        
        if ([seedPhrase isEqual:@"wipe"]) {
            masterPubKeyBIP44 = [NSData data]; // watch only wallet
            masterPubKeyBIP32 = [NSData data];
        }
        if (seedPhrase) {
            setKeychainData(masterPubKeyBIP44, EXTENDED_0_PUBKEY_KEY_BIP44, NO);
            setKeychainData(masterPubKeyBIP32, EXTENDED_0_PUBKEY_KEY_BIP32, NO);
        }
        _wallet = nil;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletManagerSeedChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletBalanceChangedNotification object:nil];
    });
}

// interval since refrence date, 00:00:00 01/01/01 GMT
- (NSTimeInterval)seedCreationTime
{
    NSData *d = getKeychainData(CREATION_TIME_KEY, nil);
    
    if (d.length == sizeof(NSTimeInterval)) return *(const NSTimeInterval *)d.bytes;
    return (self.watchOnly) ? 0 : BIP39_CREATION_TIME;
}

// private key for signing authenticated api calls
- (NSString *)authPrivateKey
{
    @autoreleasepool {
        NSString *privKey = getKeychainString(AUTH_PRIVKEY_KEY, nil);
        
        if (! privKey) {
            NSData *seed = [self.mnemonic deriveKeyFromPhrase:getKeychainString(MNEMONIC_KEY, nil) withPassphrase:nil];
            
            privKey = [[BRBIP32Sequence new] authPrivateKeyFromSeed:seed];
            setKeychainString(privKey, AUTH_PRIVKEY_KEY, NO);
        }
        
        return privKey;
    }
}

- (NSDictionary *)userAccount
{
    return getKeychainDict(USER_ACCOUNT_KEY, nil);
}

- (void)setUserAccount:(NSDictionary *)userAccount
{
    setKeychainDict(userAccount, USER_ACCOUNT_KEY, NO);
}

// true if touch id is enabled
- (BOOL)isTouchIdEnabled
{
    return ([LAContext class] &&
            [[LAContext new] canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:nil]) ? YES : NO;
}

// true if device passcode is enabled
- (BOOL)isPasscodeEnabled
{
    NSError *error = nil;
    
    if (! [LAContext class]) return YES; // we can only check for passcode on iOS 8 and above
    if ([[LAContext new] canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error]) return YES;
    return (error && error.code == LAErrorPasscodeNotSet) ? NO : YES;
}

// generates a random seed, saves to keychain and returns the associated seedPhrase
- (NSString *)generateRandomSeed
{
    @autoreleasepool {
        NSMutableData *entropy = [NSMutableData secureDataWithLength:SEED_ENTROPY_LENGTH];
        NSTimeInterval time = [NSDate timeIntervalSinceReferenceDate];
        
        if (SecRandomCopyBytes(kSecRandomDefault, entropy.length, entropy.mutableBytes) != 0) return nil;
        
        NSString *phrase = [self.mnemonic encodePhrase:entropy];
        
        self.seedPhrase = phrase;
        
        // we store the wallet creation time on the keychain because keychain data persists even when an app is deleted
        setKeychainData([NSData dataWithBytes:&time length:sizeof(time)], CREATION_TIME_KEY, NO);
        return phrase;
    }
}

// authenticates user and returns seed
- (void)seedWithPrompt:(NSString *)authprompt forAmount:(uint64_t)amount completion:(void (^)(NSData * seed))completion
{
    @autoreleasepool {
        BOOL touchid = (self.wallet.totalSent + amount < getKeychainInt(SPEND_LIMIT_KEY, nil)) ? YES : NO;
        
        [self authenticateWithPrompt:authprompt andTouchId:touchid alertIfLockout:YES completion:^(BOOL authenticated,BOOL cancelled) {
            if (!authenticated) {
                completion(nil);
            } else {
                // BUG: if user manually chooses to enter pin, the touch id spending limit is reset, but the tx being authorized
                // still counts towards the next touch id spending limit
                if (! touchid) setKeychainInt(self.wallet.totalSent + amount + self.spendingLimit, SPEND_LIMIT_KEY, NO);
                completion([self.mnemonic deriveKeyFromPhrase:getKeychainString(MNEMONIC_KEY, nil) withPassphrase:nil]);
            }
        }];
        
    }
}

// authenticates user and returns seedPhrase
- (void)seedPhraseWithPrompt:(NSString *)authprompt completion:(void (^)(NSString * seedPhrase))completion
{
    @autoreleasepool {
        [self authenticateWithPrompt:authprompt andTouchId:NO alertIfLockout:YES completion:^(BOOL authenticated,BOOL cancelled) {
            NSString * rSeedPhrase = authenticated?getKeychainString(MNEMONIC_KEY, nil):nil;
            completion(rSeedPhrase);
        }];
    }
}

// MARK: - authentication

// prompts user to authenticate with touch id or passcode
- (void)authenticateWithPrompt:(NSString *)authprompt andTouchId:(BOOL)touchId alertIfLockout:(BOOL)alertIfLockout completion:(PinCompletionBlock)completion;
{
    if (touchId) {
        NSTimeInterval pinUnlockTime = [[NSUserDefaults standardUserDefaults] doubleForKey:PIN_UNLOCK_TIME_KEY];
        LAContext *context = [[LAContext alloc] init];
        NSError *error = nil;
        if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&error] &&
            pinUnlockTime + 7*24*60*60 > [NSDate timeIntervalSinceReferenceDate] &&
            getKeychainInt(PIN_FAIL_COUNT_KEY, nil) == 0 && getKeychainInt(SPEND_LIMIT_KEY, nil) > 0) {
            
            void(^localAuthBlock)(void) = ^{
                [self performLocalAuthenticationSynchronously:context
                                                       prompt:authprompt
                                                   completion:^(BOOL authenticated, BOOL shouldTryAnotherMethod) {
                                                       if (shouldTryAnotherMethod) {
                                                           [self authenticateWithPrompt:authprompt
                                                                             andTouchId:NO
                                                                         alertIfLockout:alertIfLockout
                                                                             completion:completion];
                                                       }
                                                       else {
                                                           completion(authenticated, NO);
                                                       }
                                                   }];
            };
            
            BOOL shouldPreprompt = NO;
            if (@available(iOS 11.0, *)) {
                if (context.biometryType == LABiometryTypeFaceID) {
                    shouldPreprompt = YES;
                }
            }
            if (authprompt && shouldPreprompt) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"confirm", nil)
                                                                               message:authprompt
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"cancel", nil)
                                                                       style:UIAlertActionStyleCancel
                                                                     handler:^(UIAlertAction * action) {
                                                                         completion(NO, YES);
                                                                     }];
                [alert addAction:cancelAction];
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction * action) {
                                                                     localAuthBlock();
                                                                 }];
                [alert addAction:okAction];
                [self presentAlertController:alert animated:YES completion:nil];
            }
            else {
                localAuthBlock();
            }
        }
        else {
            NSLog(@"[LAContext canEvaluatePolicy:] %@", error.localizedDescription);
            
            [self authenticateWithPrompt:authprompt
                              andTouchId:NO
                          alertIfLockout:alertIfLockout
                              completion:completion];
        }
    }
    else {
        // TODO explain reason when touch id is disabled after 30 days without pin unlock
        [self authenticatePinWithTitle:[NSString stringWithFormat:NSLocalizedString(@"passcode for %@", nil),
                                        DISPLAY_NAME] message:authprompt alertIfLockout:alertIfLockout completion:^(BOOL authenticated, BOOL cancelled) {
            if (authenticated) {
                [self.pinAlertController dismissViewControllerAnimated:TRUE completion:^{
                    completion(YES,NO);
                }];
            } else {
                completion(NO,cancelled);
            }
        }];
    }
}

- (void)performLocalAuthenticationSynchronously:(LAContext *)context
                                         prompt:(NSString *)prompt
                                     completion:(void(^)(BOOL authenticated, BOOL shouldTryAnotherMethod))completion {
    [BREventManager saveEvent:@"wallet_manager:touchid_auth"];
    
    __block NSInteger result = 0;
    context.localizedFallbackTitle = NSLocalizedString(@"passcode", nil);
    [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
            localizedReason:(prompt.length > 0 ? prompt : @" ")
                      reply:^(BOOL success, NSError *error) {
                          result = success ? 1 : error.code;
                      }];
    
    while (result == 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    
    if (result == LAErrorAuthenticationFailed) {
        setKeychainInt(0, SPEND_LIMIT_KEY, NO); // require pin entry for next spend
    }
    else if (result == 1) {
        self.didAuthenticate = YES;
        completion(YES, NO);
        return;
    }
    else if (result == LAErrorUserCancel || result == LAErrorSystemCancel) {
        completion(NO, NO);
        return;
    }
    
    completion(NO, YES);
}

- (BOOL)isTestnet {
#if DASH_TESTNET
    return true;
#else
    return false;
#endif
}

- (UITextField *)pinField
{
    if (_pinField) return _pinField;
    _pinField = [UITextField new];
    _pinField.alpha = 0.0;
    _pinField.font = [UIFont systemFontOfSize:0.1];
    _pinField.keyboardType = UIKeyboardTypeNumberPad;
    _pinField.secureTextEntry = YES;
    _pinField.delegate = self;
    return _pinField;
}

-(BOOL)pinAlertControllerIsVisible {
    if ([[[self presentingViewController] presentedViewController] isKindOfClass:[UIAlertController class]]) {
        // UIAlertController is presenting.Here
        return TRUE;
    }
    return FALSE;
}

-(UIViewController*)presentingViewController {
    UIViewController *topController = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    while (topController.presentedViewController && ![topController.presentedViewController isKindOfClass:[UIAlertController class]]) {
        topController = topController.presentedViewController;
    }
    if ([topController isKindOfClass:[UINavigationController class]]) {
        topController = ((UINavigationController*)topController).topViewController;
    }
    return topController;
}

-(void)presentAlertController:(UIAlertController*)alertController animated:(BOOL)animated completion:(void (^ __nullable)(void))completion {
    [[self presentingViewController] presentViewController:alertController animated:animated completion:completion];
}

-(void)shakeEffectWithCompletion:(void (^ _Nullable)(void))completion {
    // walking the view hierarchy is prone to breaking, but it's still functional even if the animation doesn't work
    UIView *v = [self pinTitleView].superview;
    CGPoint p = v.center;
    
    [UIView animateWithDuration:0.05 delay:0.1 options:UIViewAnimationOptionCurveEaseInOut animations:^{ // shake
        v.center = CGPointMake(p.x + 30.0, p.y);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.5 delay:0.0 usingSpringWithDamping:0.2 initialSpringVelocity:0.0 options:0
                         animations:^{ v.center = p; } completion:^(BOOL finished) {
                             completion();
                         }];
    }];
    
}

-(NSTimeInterval)lockoutWaitTime {
    NSError * error = nil;
    uint64_t failHeight = getKeychainInt(PIN_FAIL_HEIGHT_KEY, &error);
    if (error) {
        return NSIntegerMax;
    }
    uint64_t failCount = getKeychainInt(PIN_FAIL_COUNT_KEY, &error);
    if (error) {
        return NSIntegerMax;
    }
    NSTimeInterval wait = failHeight + pow(6, failCount - 3)*60.0 -
    (self.secureTime + NSTimeIntervalSince1970);
    return wait;
}

-(void)showResetWalletWithCancelHandler:(ResetCancelHandlerBlock)resetCancelHandlerBlock {
    UIAlertController * alertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"recovery phrase", nil) message:nil
                                                                       preferredStyle:UIAlertControllerStyleAlert];
    [alertController addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.returnKeyType = UIReturnKeyDone;
        textField.font = [UIFont systemFontOfSize:15.0];
        textField.delegate = self;
    }];
    UIAlertAction* cancelButton = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"cancel", nil)
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction * action) {
                                       if (resetCancelHandlerBlock) {
                                            resetCancelHandlerBlock();
                                       }
                                   }];
    [alertController addAction:cancelButton];
    [self presentAlertController:alertController animated:YES completion:nil];
    self.resetAlertController = alertController;
}

-(void)userLockedOut {
    NSError * error = nil;
    uint64_t failHeight = getKeychainInt(PIN_FAIL_HEIGHT_KEY, &error);
    if (error) {
        return;
    }
    uint64_t failCount = getKeychainInt(PIN_FAIL_COUNT_KEY, &error);
    if (error) {
        return;
    }
    NSTimeInterval wait = [self lockoutWaitTime];
    NSString *unit = NSLocalizedString(@"minutes", nil);
    
    if (wait > pow(6, failCount - 3)) wait = pow(6, failCount - 3); // we don't have secureTime yet
    if (wait < 2.0) wait = 1.0, unit = NSLocalizedString(@"minute", nil);
    
    if (wait >= 60.0) {
        wait /= 60.0;
        unit = (wait < 2.0) ? NSLocalizedString(@"hour", nil) : NSLocalizedString(@"hours", nil);
    }
    UIAlertController * alertController = [UIAlertController
                                           alertControllerWithTitle:NSLocalizedString(@"wallet disabled", nil)
                                           message:[NSString stringWithFormat:NSLocalizedString(@"\ntry again in %d %@", nil),
                                                    (int)wait, unit]
                                           preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* resetButton = [UIAlertAction
                                  actionWithTitle:NSLocalizedString(@"reset", nil)
                                  style:UIAlertActionStyleDefault
                                  handler:^(UIAlertAction * action) {
                                      [self showResetWalletWithCancelHandler:nil];
                                  }];
    UIAlertAction* okButton = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"ok", nil)
                               style:UIAlertActionStyleCancel
                               handler:^(UIAlertAction * action) {
                                   
                               }];
    [alertController addAction:resetButton];
    [alertController addAction:okButton]; //ok button should be on the right side as per Apple guidelines, as reset is the less desireable option
    
    if ([self pinAlertControllerIsVisible]) {
        [_pinField resignFirstResponder];
        [self.pinAlertController dismissViewControllerAnimated:TRUE completion:^{
            [self presentAlertController:alertController animated:YES completion:nil];
        }];
    } else {
        [self presentAlertController:alertController animated:YES completion:nil];
    }
}

- (void)authenticatePinWithTitle:(NSString *)title message:(NSString *)message alertIfLockout:(BOOL)alertIfLockout completion:(PinCompletionBlock)completion
{
    
    //authentication logic is as follows
    //you have 3 failed attempts initially
    //after that you get locked out once immediately with a message saying
    //then you have 4 attempts with exponentially increasing intervals to get your password right
    
    [BREventManager saveEvent:@"wallet_manager:pin_auth"];
    
    NSError *error = nil;
    NSString *pin = getKeychainString(PIN_KEY, &error);
    
    if (error) {
        completion(NO,NO); // error reading pin from keychain
        return;
    }
    if (pin.length != 4) {
        [self setPinWithCompletion:^(BOOL success) {
            completion(success,NO);
        }];
        return;
    }
    
    uint64_t failCount = getKeychainInt(PIN_FAIL_COUNT_KEY, &error);
    
    if (error) {
        completion(NO,NO);
        return; // error reading failCount from keychain
    }
    
    //// Logic explanation
    
    //  If we have failed 3 or more times
    if (failCount >= 3) {
        
        // When was the last time we failed?
        uint64_t failHeight = getKeychainInt(PIN_FAIL_HEIGHT_KEY, &error);
        
        if (error) {
            completion(NO,NO);
            return; // error reading failHeight from keychain
        }
        NSLog(@"locked out for %f more seconds",failHeight + pow(6, failCount - 3)*60.0 - self.secureTime - NSTimeIntervalSince1970);
        if (self.secureTime + NSTimeIntervalSince1970 < failHeight + pow(6, failCount - 3)*60.0) { // locked out
            if (alertIfLockout) {
                [self userLockedOut];
            }
            completion(NO,NO);
            return;
        } else {
            //no longer locked out, give the user a try
            message = [(failCount >= 7 ? NSLocalizedString(@"\n1 attempt remaining\n", nil) :
                        [NSString stringWithFormat:NSLocalizedString(@"\n%d attempts remaining\n", nil), 8 - failCount])
                       stringByAppendingString:(message) ? message : @""];
        }
    }
    
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:[NSString stringWithFormat:CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\n%@",
                                                           (title) ? title : @""]
                                 message:message
                                 preferredStyle:UIAlertControllerStyleAlert];
    self.pinAlertController = alert;
    self.pinField = nil; // reset pinField so a new one is created
    [self.pinAlertController.view addSubview:self.pinField];
    UIAlertAction* cancelButton = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"cancel", nil)
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction * action) {
                                       completion(NO,YES);
                                   }];
    [self.pinAlertController addAction:cancelButton];
    
    self.pinVerificationBlock = ^BOOL(NSString * currentPin,BRWalletManager * context) {
        NSError * error = nil;
        uint64_t failCount = getKeychainInt(PIN_FAIL_COUNT_KEY, &error);
        
        if (error) {
            completion(NO,NO); // error reading failCount from keychain
            [alert dismissViewControllerAnimated:TRUE completion:nil];
            return FALSE;
        }
        
        NSString *pin = getKeychainString(PIN_KEY, &error);
        
        if (error) {
            completion(NO,NO); // error reading pin from keychain
            [alert dismissViewControllerAnimated:TRUE completion:nil];
            return FALSE;
        }
        // count unique attempts before checking success
        if (! [context.failedPins containsObject:currentPin]) setKeychainInt(++failCount, PIN_FAIL_COUNT_KEY, NO);
        
        if ([currentPin isEqual:pin]) { // successful pin attempt
            [context.failedPins removeAllObjects];
            context.didAuthenticate = YES;
            uint64_t limit = context.spendingLimit;
            setKeychainInt(0, PIN_FAIL_COUNT_KEY, NO);
            setKeychainInt(0, PIN_FAIL_HEIGHT_KEY, NO);
            if (limit > 0) setKeychainInt(self.wallet.totalSent + limit, SPEND_LIMIT_KEY, NO);
            [[NSUserDefaults standardUserDefaults] setDouble:[NSDate timeIntervalSinceReferenceDate]
                                                      forKey:PIN_UNLOCK_TIME_KEY];
            if (completion) completion(YES,NO);
            return TRUE;
        }
        
        if (! [context.failedPins containsObject:currentPin]) {
            [context.failedPins addObject:currentPin];
            
            if (failCount >= 8) { // wipe wallet after 8 failed pin attempts and 24+ hours of lockout
                context.seedPhrase = nil;
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/10), dispatch_get_main_queue(), ^{
                    exit(0);
                });
                if (completion) completion(NO,NO);
                return FALSE;
            }
            
            if (self.secureTime + NSTimeIntervalSince1970 > getKeychainInt(PIN_FAIL_HEIGHT_KEY, nil)) {
                setKeychainInt(self.secureTime + NSTimeIntervalSince1970, PIN_FAIL_HEIGHT_KEY, NO);
            }
            
            if (failCount >= 3) {
                [context.pinAlertController dismissViewControllerAnimated:TRUE completion:^{
                    if (alertIfLockout) {
                        [context userLockedOut]; // wallet disabled
                    }
                    completion(NO,NO);
                }];
                return FALSE;
            }
        }
        [context shakeEffectWithCompletion:^{
            context.pinField.text = @"";
        }];
        return FALSE;
    };
    
    [self presentAlertController:self.pinAlertController animated:YES completion:^{
        if (_pinField && ! _pinField.isFirstResponder) [_pinField becomeFirstResponder];
    }];
}



// amount that can be spent using touch id without pin entry
- (uint64_t)spendingLimit
{
    // it's ok to store this in userdefaults because increasing the value only takes effect after successful pin entry
    if (! [[NSUserDefaults standardUserDefaults] objectForKey:SPEND_LIMIT_AMOUNT_KEY]) return DUFFS;
    
    return [[NSUserDefaults standardUserDefaults] doubleForKey:SPEND_LIMIT_AMOUNT_KEY];
}

- (void)setSpendingLimit:(uint64_t)spendingLimit
{
    if (setKeychainInt((spendingLimit > 0) ? self.wallet.totalSent + spendingLimit : 0, SPEND_LIMIT_KEY, NO)) {
        // use setDouble since setInteger won't hold a uint64_t
        [[NSUserDefaults standardUserDefaults] setDouble:spendingLimit forKey:SPEND_LIMIT_AMOUNT_KEY];
    }
}

// last known time from an ssl server connection
- (NSTimeInterval)secureTime
{
    return [[NSUserDefaults standardUserDefaults] doubleForKey:SECURE_TIME_KEY];
}

// MARK: - exchange rate

// local currency ISO code
- (void)setLocalCurrencyCode:(NSString *)code
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSUInteger i = [_currencyCodes indexOfObject:code];
    
    if (i == NSNotFound) code = DEFAULT_CURRENCY_CODE, i = [_currencyCodes indexOfObject:DEFAULT_CURRENCY_CODE];
    _localCurrencyCode = [code copy];
    
    if (i < _currencyPrices.count && self.secureTime + 3*24*60*60 > [NSDate timeIntervalSinceReferenceDate]) {
        self.localCurrencyBitcoinPrice = _currencyPrices[i]; // don't use exchange rate data more than 72hrs out of date
    }
    else self.localCurrencyBitcoinPrice = @(0);
    
    self.localFormat.currencyCode = _localCurrencyCode;
    self.localFormat.maximum =
    [[NSDecimalNumber decimalNumberWithDecimal:self.localCurrencyBitcoinPrice.decimalValue]
     decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithLongLong:MAX_MONEY/DUFFS]];
    
    if ([self.localCurrencyCode isEqual:[[NSLocale currentLocale] objectForKey:NSLocaleCurrencyCode]]) {
        [defs removeObjectForKey:LOCAL_CURRENCY_CODE_KEY];
    }
    else [defs setObject:self.localCurrencyCode forKey:LOCAL_CURRENCY_CODE_KEY];
    
    if (! _wallet) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletBalanceChangedNotification object:nil];
    });
}

// MARK: - new pin

// prompts the user to set or change their wallet pin and returns true if the pin was successfully set
- (void)setBrandNewPinWithCompletion:(void (^ _Nullable)(BOOL success))completion {
    NSString *title = [NSString stringWithFormat:CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\n%@",
                       [NSString stringWithFormat:NSLocalizedString(@"choose passcode for %@", nil), DISPLAY_NAME]];
    if (!self.pinAlertController) {
        self.pinAlertController = [UIAlertController
                                   alertControllerWithTitle:title
                                   message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];
        if (_pinField) self.pinField = nil; // reset pinField so a new one is created
        [self.pinAlertController.view addSubview:self.pinField];
        [self presentAlertController:self.pinAlertController animated:YES completion:^{
            [_pinField becomeFirstResponder];
        }];
    } else {
        self.pinField.delegate = nil;
        self.pinField.text = @"";
        self.pinField.delegate = self;
        self.pinAlertController.title = title;
    }
    self.pinVerificationBlock = ^BOOL(NSString * currentPin,BRWalletManager * context) {
        [context setVerifyPin:currentPin withCompletion:completion];
        return TRUE;
    };
}

- (void)setVerifyPin:(NSString*)previousPin withCompletion:(void (^ _Nullable)(BOOL success))completion {
    self.pinField.text = nil;
    
    UIView *v = [self pinTitleView].superview;
    CGPoint p = v.center;
    
    [UIView animateWithDuration:0.1 delay:0.1 options:UIViewAnimationOptionCurveEaseIn animations:^{ // verify pin
        v.center = CGPointMake(p.x - v.bounds.size.width, p.y);
    } completion:^(BOOL finished) {
        self.pinAlertController.title = [NSString stringWithFormat:CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\n%@",
                                         NSLocalizedString(@"verify passcode", nil)];
        v.center = CGPointMake(p.x + v.bounds.size.width*2, p.y);
        [self textField:self.pinField shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:@""];
        [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0
                         animations:^{ v.center = p; } completion:nil];
    }];
    
    self.pinVerificationBlock = ^BOOL(NSString * currentPin,BRWalletManager * context) {
        if ([currentPin isEqual:previousPin]) {
            context.pinField.text = nil;
            setKeychainString(previousPin, PIN_KEY, NO);
            [[NSUserDefaults standardUserDefaults] setDouble:[NSDate timeIntervalSinceReferenceDate]
                                                      forKey:PIN_UNLOCK_TIME_KEY];
            [context.pinField resignFirstResponder];
            [context.pinAlertController dismissViewControllerAnimated:TRUE completion:^{
                if (completion) completion(YES);
            }];
            return TRUE;
        }
        
        [context shakeEffectWithCompletion:^{
            [context setBrandNewPinWithCompletion:completion];
        }];
        return FALSE;
    };
}

-(UIView*)getSubviewForView:(UIView*)view withText:(NSString*)text {
    for (UIView * subView in view.subviews) {
        if ([subView isKindOfClass:[UILabel class]] && [((UILabel*)subView).text isEqualToString:text]) return subView;
        UIView * foundView = [self getSubviewForView:subView withText:text];
        if (foundView != nil) return foundView;
    }
    return nil;
}

-(UIView*)pinTitleView {
    return [self getSubviewForView:self.pinAlertController.view withText:self.pinAlertController.title];
}

// prompts the user to set or change their wallet pin and returns true if the pin was successfully set
- (void)setPinWithCompletion:(void (^ _Nullable)(BOOL success))completion
{
    NSError *error = nil;
    NSString *pin = getKeychainString(PIN_KEY, &error);
    
    if (error) {
        if (completion) completion(NO);
        return; // error reading existing pin from keychain
    }
    
    [BREventManager saveEvent:@"wallet_manager:set_pin"];
    
    if (pin.length == 4) { //already had a pin, replacing it
        [self authenticatePinWithTitle:NSLocalizedString(@"enter old passcode", nil) message:nil alertIfLockout:YES completion:^(BOOL authenticated,BOOL cancelled) {
            if (authenticated) {
                self.didAuthenticate = FALSE;
                UIView *v = [self pinTitleView].superview;
                CGPoint p = v.center;
                
                [UIView animateWithDuration:0.1 delay:0.1 options:UIViewAnimationOptionCurveEaseIn animations:^{
                    v.center = CGPointMake(p.x - v.bounds.size.width, p.y);
                } completion:^(BOOL finished) {
                    self.pinAlertController.title = [NSString stringWithFormat:CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\n%@",
                                                     [NSString stringWithFormat:NSLocalizedString(@"choose passcode for %@", nil), DISPLAY_NAME]];
                    self.pinAlertController.message = nil;
                    v.center = CGPointMake(p.x + v.bounds.size.width*2, p.y);
                    [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0
                                     animations:^{ v.center = p; } completion:nil];
                }];
                [self setBrandNewPinWithCompletion:completion];
            } else {
                if (completion) completion(NO);
            }
        }];
    }
    else { //didn't have a pin yet
        [self setBrandNewPinWithCompletion:completion];
    }
}

// MARK: - floating fees

- (void)updateFeePerKb
{
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
#if (!!FEE_PER_KB_URL)
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:FEE_PER_KB_URL]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];
    
    //    NSLog(@"%@", req.URL.absoluteString);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         if (error != nil) {
                                             NSLog(@"unable to fetch fee-per-kb: %@", error);
                                             return;
                                         }
                                         
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         
                                         if (error || ! [json isKindOfClass:[NSDictionary class]] ||
                                             ! [json[@"fee_per_kb"] isKindOfClass:[NSNumber class]]) {
                                             NSLog(@"unexpected response from %@:\n%@", req.URL.host,
                                                   [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                                             return;
                                         }
                                         
                                         uint64_t newFee = [json[@"fee_per_kb"] unsignedLongLongValue];
                                         NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                         
                                         if (newFee >= MIN_FEE_PER_KB && newFee <= MAX_FEE_PER_KB && newFee != [defs doubleForKey:FEE_PER_KB_KEY]) {
                                             NSLog(@"setting new fee-per-kb %lld", newFee);
                                             [defs setDouble:newFee forKey:FEE_PER_KB_KEY]; // use setDouble since setInteger won't hold a uint64_t
                                             _wallet.feePerKb = newFee;
                                         }
                                     }] resume];
    
#else
    return;
#endif
}

-(NSNumber*)bitcoinDashPrice {
    if (_bitcoinDashPrice.doubleValue == 0) {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        
        double poloniexPrice = [[defs objectForKey:POLONIEX_DASH_BTC_PRICE_KEY] doubleValue];
        double dashcentralPrice = [[defs objectForKey:DASHCENTRAL_DASH_BTC_PRICE_KEY] doubleValue];
        if (poloniexPrice > 0) {
            if (dashcentralPrice > 0) {
                _bitcoinDashPrice = @((poloniexPrice + dashcentralPrice)/2.0);
            } else {
                _bitcoinDashPrice = @(poloniexPrice);
            }
        } else if (dashcentralPrice > 0) {
            _bitcoinDashPrice = @(dashcentralPrice);
        }
    }
    return _bitcoinDashPrice;
}

- (void)refreshBitcoinDashPrice{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    double poloniexPrice = [[defs objectForKey:POLONIEX_DASH_BTC_PRICE_KEY] doubleValue];
    double dashcentralPrice = [[defs objectForKey:DASHCENTRAL_DASH_BTC_PRICE_KEY] doubleValue];
    NSNumber * newPrice = 0;
    if (poloniexPrice > 0) {
        if (dashcentralPrice > 0) {
            newPrice = @((poloniexPrice + dashcentralPrice)/2.0);
        } else {
            newPrice = @(poloniexPrice);
        }
    } else if (dashcentralPrice > 0) {
        newPrice = @(dashcentralPrice);
    }
    
    if (! _wallet ) return;
    //if ([newPrice doubleValue] == [_bitcoinDashPrice doubleValue]) return;
    _bitcoinDashPrice = newPrice;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BRWalletBalanceChangedNotification object:nil];
    });
}


// until there is a public api for dash prices among multiple currencies it's better that we pull Bitcoin prices per currency and convert it to dash
- (void)updateDashExchangeRate
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateDashExchangeRate) object:nil];
    [self performSelector:@selector(updateDashExchangeRate) withObject:nil afterDelay:TICKER_REFRESH_TIME];
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
    
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:POLONIEX_TICKER_URL]
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.0];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *connectionError) {
                                         if (((((NSHTTPURLResponse*)response).statusCode /100) != 2) || connectionError) {
                                             NSLog(@"connectionError %@ (status %ld)", connectionError,(long)((NSHTTPURLResponse*)response).statusCode);
                                             return;
                                         }
                                         if ([response isKindOfClass:[NSHTTPURLResponse class]]) { // store server timestamp
                                             NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                             NSString *date = [(NSHTTPURLResponse *)response allHeaderFields][@"Date"];
                                             NSTimeInterval now = [[[NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil]
                                                                    matchesInString:date options:0 range:NSMakeRange(0, date.length)].lastObject
                                                                   date].timeIntervalSinceReferenceDate;
                                             
                                             if (now > self.secureTime) [defs setDouble:now forKey:SECURE_TIME_KEY];
                                         }
                                         NSError *error = nil;
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         NSArray * asks = [json objectForKey:@"asks"];
                                         NSArray * bids = [json objectForKey:@"bids"];
                                         if ([asks count] && [bids count] && [[asks objectAtIndex:0] count] && [[bids objectAtIndex:0] count]) {
                                             NSString * lastTradePriceStringAsks = [[asks objectAtIndex:0] objectAtIndex:0];
                                             NSString * lastTradePriceStringBids = [[bids objectAtIndex:0] objectAtIndex:0];
                                             if (lastTradePriceStringAsks && lastTradePriceStringBids) {
                                                 NSNumberFormatter *numberFormatter = [[NSNumberFormatter alloc] init];
                                                 NSLocale *usa = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
                                                 numberFormatter.locale = usa;
                                                 numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
                                                 NSNumber *lastTradePriceNumberAsks = [numberFormatter numberFromString:lastTradePriceStringAsks];
                                                 NSNumber *lastTradePriceNumberBids = [numberFormatter numberFromString:lastTradePriceStringBids];
                                                 NSNumber * lastTradePriceNumber = @((lastTradePriceNumberAsks.floatValue + lastTradePriceNumberBids.floatValue) / 2);
                                                 NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                                 [defs setObject:lastTradePriceNumber forKey:POLONIEX_DASH_BTC_PRICE_KEY];
                                                 [defs setObject:[NSDate date] forKey:POLONIEX_DASH_BTC_UPDATE_TIME_KEY];
                                                 [defs synchronize];
                                                 [self refreshBitcoinDashPrice];
                                             }
                                         }
#if EXCHANGE_RATES_LOGGING
                                         NSLog(@"poloniex exchange rate updated to %@/%@", [self localCurrencyStringForDashAmount:DUFFS],
                                               [self stringForDashAmount:DUFFS]);
#endif
                                     }
      ] resume];
    
}

// until there is a public api for dash prices among multiple currencies it's better that we pull Bitcoin prices per currency and convert it to dash
- (void)updateDashCentralExchangeRateFallback
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateDashCentralExchangeRateFallback) object:nil];
    [self performSelector:@selector(updateDashCentralExchangeRateFallback) withObject:nil afterDelay:TICKER_REFRESH_TIME];
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
    
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:DASHCENTRAL_TICKER_URL]
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.0];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *connectionError) {
                                         if (((((NSHTTPURLResponse*)response).statusCode /100) != 2) || connectionError) {
                                             NSLog(@"connectionError %@ (status %ld)", connectionError,(long)((NSHTTPURLResponse*)response).statusCode);
                                             return;
                                         }
                                         
                                         if ([response isKindOfClass:[NSHTTPURLResponse class]]) { // store server timestamp
                                             NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                             NSString *date = [(NSHTTPURLResponse *)response allHeaderFields][@"Date"];
                                             NSTimeInterval now = [[[NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil]
                                                                    matchesInString:date options:0 range:NSMakeRange(0, date.length)].lastObject
                                                                   date].timeIntervalSinceReferenceDate;
                                             
                                             if (now > self.secureTime) [defs setDouble:now forKey:SECURE_TIME_KEY];
                                         }
                                         
                                         NSError *error = nil;
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         if (!error) {
                                             NSNumber * dash_usd = @([[[json objectForKey:@"exchange_rates"] objectForKey:@"btc_dash"] doubleValue]);
                                             if (dash_usd && [dash_usd doubleValue] > 0) {
                                                 NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                                 
                                                 [defs setObject:dash_usd forKey:DASHCENTRAL_DASH_BTC_PRICE_KEY];
                                                 [defs setObject:[NSDate date] forKey:DASHCENTRAL_DASH_BTC_UPDATE_TIME_KEY];
                                                 [defs synchronize];
                                                 [self refreshBitcoinDashPrice];
#if EXCHANGE_RATES_LOGGING
                                                 NSLog(@"dash central exchange rate updated to %@/%@", [self localCurrencyStringForDashAmount:DUFFS],
                                                       [self stringForDashAmount:DUFFS]);
#endif
                                             }
                                         }
                                     }
      ] resume];
    
}

- (void)updateBitcoinExchangeRate
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateBitcoinExchangeRate) object:nil];
    [self performSelector:@selector(updateBitcoinExchangeRate) withObject:nil afterDelay:TICKER_REFRESH_TIME];
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:BITCOIN_TICKER_URL]
                                         cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *connectionError) {
        if (((((NSHTTPURLResponse*)response).statusCode /100) != 2) || connectionError) {
            NSLog(@"connectionError %@ (status %ld)", connectionError,(long)((NSHTTPURLResponse*)response).statusCode);
            return;
        }
        
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        NSError *error = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSMutableArray *codes = [NSMutableArray array], *names = [NSMutableArray array], *rates =[NSMutableArray array];
        
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) { // store server timestamp
            NSString *date = [(NSHTTPURLResponse *)response allHeaderFields][@"Date"];
            NSTimeInterval now = [[[NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil]
                                   matchesInString:date options:0 range:NSMakeRange(0, date.length)].lastObject
                                  date].timeIntervalSinceReferenceDate;
            
            if (now > self.secureTime) [defs setDouble:now forKey:SECURE_TIME_KEY];
        }
        
        if (error || ! [json isKindOfClass:[NSDictionary class]] || ! [json[@"data"] isKindOfClass:[NSArray class]]) {
            NSLog(@"unexpected response from %@:\n%@", req.URL.host,
                  [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
            return;
        }
        
        for (NSDictionary *d in json[@"data"]) {
            if (! [d isKindOfClass:[NSDictionary class]] || ! [d[@"code"] isKindOfClass:[NSString class]] ||
                ! [d[@"name"] isKindOfClass:[NSString class]] || ! [d[@"rate"] isKindOfClass:[NSNumber class]]) {
                NSLog(@"unexpected response from %@:\n%@", req.URL.host,
                      [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                return;
            }
            
            if ([d[@"code"] isEqual:@"BTC"]) continue;
            [codes addObject:d[@"code"]];
            [names addObject:d[@"name"]];
            [rates addObject:d[@"rate"]];
        }
        
        _currencyCodes = codes;
        _currencyNames = names;
        _currencyPrices = rates;
        self.localCurrencyCode = _localCurrencyCode; // update localCurrencyPrice and localFormat.maximum
        [defs setObject:self.currencyCodes forKey:CURRENCY_CODES_KEY];
        [defs setObject:self.currencyNames forKey:CURRENCY_NAMES_KEY];
        [defs setObject:self.currencyPrices forKey:CURRENCY_PRICES_KEY];
        [defs synchronize];
#if EXCHANGE_RATES_LOGGING
        NSLog(@"bitcoin exchange rate updated to %@/%@", [self localCurrencyStringForDashAmount:DUFFS],
              [self stringForDashAmount:DUFFS]);
#endif
    }
      
      
      ] resume];
    
}


// MARK: - query unspent outputs

// queries api.breadwallet.com and calls the completion block with unspent outputs for the given addresses
- (void)utxosForAddresses:(NSArray *)addresses
               completion:(void (^)(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *error))completion
{
    [self utxos:UNSPENT_URL forAddresses:addresses
     completion:^(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *error) {
         if (error) {
             [self utxos:UNSPENT_FAILOVER_URL forAddresses:addresses
              completion:^(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *err) {
                  if (err) err = error;
                  completion(utxos, amounts, scripts, err);
              }];
         }
         else completion(utxos, amounts, scripts, error);
     }];
}

- (void)utxos:(NSString *)unspentURL forAddresses:(NSArray *)addresses
   completion:(void (^)(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *error))completion
{
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:unspentURL]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:20.0];
    NSMutableArray *args = [NSMutableArray array];
    NSMutableCharacterSet *charset = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    
    [charset removeCharactersInString:@"&="];
    [args addObject:[@"addrs=" stringByAppendingString:[[addresses componentsJoinedByString:@","]
                                                        stringByAddingPercentEncodingWithAllowedCharacters:charset]]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [[args componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    NSLog(@"%@ POST: %@", req.URL.absoluteString,
          [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding]);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         if (error) {
                                             completion(nil, nil, nil, error);
                                             return;
                                         }
                                         
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         NSMutableArray *utxos = [NSMutableArray array], *amounts = [NSMutableArray array],
                                         *scripts = [NSMutableArray array];
                                         BRUTXO o;
                                         
                                         if (error || ! [json isKindOfClass:[NSArray class]]) {
                                             NSLog(@"Error decoding response %@",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                                             completion(nil, nil, nil,
                                                        [NSError errorWithDomain:@"DashWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                                                                                                                       [NSString stringWithFormat:NSLocalizedString(@"unexpected response from %@", nil),
                                                                                                                        req.URL.host]}]);
                                             return;
                                         }
                                         
                                         for (NSDictionary *utxo in json) {
                                             
                                             NSDecimalNumber * amount = nil;
                                             if (utxo[@"amount"]) {
                                                 if ([utxo[@"amount"] isKindOfClass:[NSString class]]) {
                                                     amount = [NSDecimalNumber decimalNumberWithString:utxo[@"amount"]];
                                                 } else if ([utxo[@"amount"] isKindOfClass:[NSDecimalNumber class]]) {
                                                     amount = utxo[@"amount"];
                                                 } else if ([utxo[@"amount"] isKindOfClass:[NSNumber class]]) {
                                                     amount = [NSDecimalNumber decimalNumberWithDecimal:[utxo[@"amount"] decimalValue]];
                                                 }
                                             }
                                             if (! [utxo isKindOfClass:[NSDictionary class]] ||
                                                 ! [utxo[@"txid"] isKindOfClass:[NSString class]] ||
                                                 [utxo[@"txid"] hexToData].length != sizeof(UInt256) ||
                                                 ! [utxo[@"vout"] isKindOfClass:[NSNumber class]] ||
                                                 ! [utxo[@"scriptPubKey"] isKindOfClass:[NSString class]] ||
                                                 ! [utxo[@"scriptPubKey"] hexToData] ||
                                                 (! [utxo[@"duffs"] isKindOfClass:[NSNumber class]] && ! [utxo[@"satoshis"] isKindOfClass:[NSNumber class]] && !amount)) {
                                                 completion(nil, nil, nil,
                                                            [NSError errorWithDomain:@"DashWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                                                                                                                           [NSString stringWithFormat:NSLocalizedString(@"unexpected response from %@", nil),
                                                                                                                            req.URL.host]}]);
                                                 return;
                                             }
                                             
                                             o.hash = *(const UInt256 *)[utxo[@"txid"] hexToData].reverse.bytes;
                                             o.n = [utxo[@"vout"] unsignedIntValue];
                                             [utxos addObject:brutxo_obj(o)];
                                             if (amount) {
                                                 [amounts addObject:[amount decimalNumberByMultiplyingByPowerOf10:8]];
                                             } else if (utxo[@"duffs"]) {
                                                 [amounts addObject:utxo[@"duffs"]];
                                             }  else if (utxo[@"satoshis"]) {
                                                 [amounts addObject:utxo[@"satoshis"]];
                                             }
                                             [scripts addObject:[utxo[@"scriptPubKey"] hexToData]];
                                         }
                                         
                                         completion(utxos, amounts, scripts, nil);
                                     }] resume];
}

// given a private key, queries dash insight for unspent outputs and calls the completion block with a signed transaction
// that will sweep the balance into the wallet (doesn't publish the tx)
- (void)sweepPrivateKey:(NSString *)privKey withFee:(BOOL)fee
             completion:(void (^)(BRTransaction *tx, uint64_t fee, NSError *error))completion
{
    if (! completion) return;
    
    if ([privKey isValidDashBIP38Key]) {
        UIAlertController * alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"password protected key", nil) message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.secureTextEntry = true;
            textField.returnKeyType = UIReturnKeyDone;
            textField.placeholder = NSLocalizedString(@"password", nil);
        }];
        UIAlertAction* cancelButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"cancel", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
        UIAlertAction* okButton = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"ok", nil)
                                   style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction * action) {
                                       NSString *passphrase = alert.textFields[0].text;
                                       
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           BRKey *key = [BRKey keyWithBIP38Key:self.sweepKey andPassphrase:passphrase];
                                           
                                           if (! key) {
                                               UIAlertController * alert = [UIAlertController
                                                                            alertControllerWithTitle:NSLocalizedString(@"password protected key", nil)
                                                                            message:NSLocalizedString(@"bad password, try again", nil)
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                                               UIAlertAction* cancelButton = [UIAlertAction
                                                                              actionWithTitle:NSLocalizedString(@"cancel", nil)
                                                                              style:UIAlertActionStyleCancel
                                                                              handler:^(UIAlertAction * action) {
                                                                                  if (self.sweepCompletion) self.sweepCompletion(nil, 0, nil);
                                                                                  self.sweepKey = nil;
                                                                                  self.sweepCompletion = nil;
                                                                              }];
                                               UIAlertAction* okButton = [UIAlertAction
                                                                          actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                          style:UIAlertActionStyleDefault
                                                                          handler:^(UIAlertAction * action) {
                                                                              
                                                                          }];
                                               [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                                                   textField.secureTextEntry = true;
                                                   textField.placeholder = @"password";
                                                   textField.clearButtonMode = UITextFieldViewModeWhileEditing;
                                                   textField.borderStyle = UITextBorderStyleRoundedRect;
                                                   textField.returnKeyType = UIReturnKeyDone;
                                               }];
                                               [alert addAction:okButton];
                                               [alert addAction:cancelButton];
                                               [self presentAlertController:alert animated:YES completion:^{
                                                   if (_pinField && ! _pinField.isFirstResponder) [_pinField becomeFirstResponder];
                                               }];
                                           }
                                           else {
                                               [self sweepPrivateKey:key.privateKey withFee:self.sweepFee completion:self.sweepCompletion];
                                               self.sweepKey = nil;
                                               self.sweepCompletion = nil;
                                           }
                                       });
                                   }];
        [alert addAction:cancelButton];
        [alert addAction:okButton];
        [self presentAlertController:alert animated:YES completion:nil];
        self.sweepKey = privKey;
        self.sweepFee = fee;
        self.sweepCompletion = completion;
        return;
    }
    
    BRKey *key = [BRKey keyWithPrivateKey:privKey];
    
    if (! key.address) {
        completion(nil, 0, [NSError errorWithDomain:@"DashWallet" code:187 userInfo:@{NSLocalizedDescriptionKey:
                                                                                          NSLocalizedString(@"not a valid private key", nil)}]);
        return;
    }
    
    if ([self.wallet containsAddress:key.address]) {
        completion(nil, 0, [NSError errorWithDomain:@"DashWallet" code:187 userInfo:@{NSLocalizedDescriptionKey:
                                                                                          NSLocalizedString(@"this private key is already in your wallet", nil)}]);
        return;
    }
    
    [self utxosForAddresses:@[key.address]
                 completion:^(NSArray *utxos, NSArray *amounts, NSArray *scripts, NSError *error) {
                     BRTransaction *tx = [BRTransaction new];
                     uint64_t balance = 0, feeAmount = 0;
                     NSUInteger i = 0;
                     
                     if (error) {
                         completion(nil, 0, error);
                         return;
                     }
                     
                     //TODO: make sure not to create a transaction larger than TX_MAX_SIZE
                     for (NSValue *output in utxos) {
                         BRUTXO o;
                         
                         [output getValue:&o];
                         [tx addInputHash:o.hash index:o.n script:scripts[i]];
                         balance += [amounts[i++] unsignedLongLongValue];
                     }
                     
                     if (balance == 0) {
                         completion(nil, 0, [NSError errorWithDomain:@"DashWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                                                                                                           NSLocalizedString(@"this private key is empty", nil)}]);
                         return;
                     }
                     
                     // we will be adding a wallet output (34 bytes), also non-compact pubkey sigs are larger by 32bytes each
                     if (fee) feeAmount = [self.wallet feeForTxSize:tx.size + 34 + (key.publicKey.length - 33)*tx.inputHashes.count isInstant:false inputCount:0]; //input count doesn't matter for non instant transactions
                     
                     if (feeAmount + self.wallet.minOutputAmount > balance) {
                         completion(nil, 0, [NSError errorWithDomain:@"DashWallet" code:417 userInfo:@{NSLocalizedDescriptionKey:
                                                                                                           NSLocalizedString(@"transaction fees would cost more than the funds available on this "
                                                                                                                             "private key (due to tiny \"dust\" deposits)",nil)}]);
                         return;
                     }
                     
                     [tx addOutputAddress:self.wallet.receiveAddress amount:balance - feeAmount];
                     
                     if (! [tx signWithPrivateKeys:@[privKey]]) {
                         completion(nil, 0, [NSError errorWithDomain:@"DashWallet" code:401 userInfo:@{NSLocalizedDescriptionKey:
                                                                                                           NSLocalizedString(@"error signing transaction", nil)}]);
                         return;
                     }
                     
                     completion(tx, feeAmount, nil);
                 }];
}

// MARK: - string helpers

#pragma mark - string helpers

- (int64_t)amountForUnknownCurrencyString:(NSString *)string
{
    if (! string.length) return 0;
    return [[[NSDecimalNumber decimalNumberWithString:string]
             decimalNumberByMultiplyingByPowerOf10:self.unknownFormat.maximumFractionDigits] longLongValue];
}

- (int64_t)amountForDashString:(NSString *)string
{
    if (! string.length) return 0;
    NSInteger dashCharPos = [string indexOfCharacter:NSAttachmentCharacter];
    if (dashCharPos != NSNotFound) {
        string = [string stringByReplacingCharactersInRange:NSMakeRange(dashCharPos, 1) withString:DASH];
    }
    return [[[NSDecimalNumber decimalNumberWithDecimal:[[self.dashFormat numberFromString:string] decimalValue]]
             decimalNumberByMultiplyingByPowerOf10:self.dashFormat.maximumFractionDigits] longLongValue];
}

- (int64_t)amountForBitcoinString:(NSString *)string
{
    if (! string.length) return 0;
    return [[[NSDecimalNumber decimalNumberWithDecimal:[[self.bitcoinFormat numberFromString:string] decimalValue]]
             decimalNumberByMultiplyingByPowerOf10:self.bitcoinFormat.maximumFractionDigits] longLongValue];
}

- (NSAttributedString *)attributedStringForDashAmount:(int64_t)amount
{
    NSString * string = [self.dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                                           decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits]];
    return [string attributedStringForDashSymbol];
}

- (NSAttributedString *)attributedStringForDashAmount:(int64_t)amount withTintColor:(UIColor*)color {
    NSString * string = [self.dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                                           decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits]];
    return [string attributedStringForDashSymbolWithTintColor:color];
}

- (NSAttributedString *)attributedStringForDashAmount:(int64_t)amount withTintColor:(UIColor*)color useSignificantDigits:(BOOL)useSignificantDigits {
    NSString * string = [(useSignificantDigits?self.dashSignificantFormat:self.dashFormat) stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                                                                                             decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits]];
    return [string attributedStringForDashSymbolWithTintColor:color];
}

- (NSAttributedString *)attributedStringForDashAmount:(int64_t)amount withTintColor:(UIColor*)color dashSymbolSize:(CGSize)dashSymbolSize
{
    NSString * string = [self.dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                                           decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits]];
    return [string attributedStringForDashSymbolWithTintColor:color dashSymbolSize:dashSymbolSize];
}

- (NSNumber *)numberForAmount:(int64_t)amount
{
    return (id)[(id)[NSDecimalNumber numberWithLongLong:amount]
                decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits];
}

- (NSString *)stringForBitcoinAmount:(int64_t)amount
{
    return [self.bitcoinFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                                 decimalNumberByMultiplyingByPowerOf10:-self.bitcoinFormat.maximumFractionDigits]];
}

- (NSString *)stringForDashAmount:(int64_t)amount
{
    return [self.dashFormat stringFromNumber:[(id)[NSDecimalNumber numberWithLongLong:amount]
                                              decimalNumberByMultiplyingByPowerOf10:-self.dashFormat.maximumFractionDigits]];
}

-(NSNumber* _Nonnull)localCurrencyDashPrice {
    if (!_bitcoinDashPrice || !_localCurrencyBitcoinPrice) {
        return _localCurrencyDashPrice;
    } else {
        return @(_bitcoinDashPrice.doubleValue * _localCurrencyBitcoinPrice.doubleValue);
    }
}

// NOTE: For now these local currency methods assume that a satoshi has a smaller value than the smallest unit of any
// local currency. They will need to be revisited when that is no longer a safe assumption.
- (int64_t)amountForLocalCurrencyString:(NSString *)string
{
    if ([string hasPrefix:@"<"]) string = [string substringFromIndex:1];
    
    NSNumber *n = [self.localFormat numberFromString:string];
    int64_t price = [[NSDecimalNumber decimalNumberWithDecimal:self.localCurrencyDashPrice.decimalValue]
                     decimalNumberByMultiplyingByPowerOf10:self.localFormat.maximumFractionDigits].longLongValue,
    local = [[NSDecimalNumber decimalNumberWithDecimal:n.decimalValue]
             decimalNumberByMultiplyingByPowerOf10:self.localFormat.maximumFractionDigits].longLongValue,
    overflowbits = 0, p = 10, min, max, amount;
    
    if (local == 0 || price < 1) return 0;
    while (llabs(local) + 1 > INT64_MAX/DUFFS) local /= 2, overflowbits++; // make sure we won't overflow an int64_t
    min = llabs(local)*DUFFS/price + 1; // minimum amount that safely matches local currency string
    max = (llabs(local) + 1)*DUFFS/price - 1; // maximum amount that safely matches local currency string
    amount = (min + max)/2; // average min and max
    while (overflowbits > 0) local *= 2, min *= 2, max *= 2, amount *= 2, overflowbits--;
    
    if (amount >= MAX_MONEY) return (local < 0) ? -MAX_MONEY : MAX_MONEY;
    while ((amount/p)*p >= min && p <= INT64_MAX/10) p *= 10; // lowest decimal precision matching local currency string
    p /= 10;
    return (local < 0) ? -(amount/p)*p : (amount/p)*p;
}


- (int64_t)amountForBitcoinCurrencyString:(NSString *)string
{
    if (self.bitcoinDashPrice.doubleValue <= DBL_EPSILON) return 0;
    if ([string hasPrefix:@"<"]) string = [string substringFromIndex:1];
    
    double price = self.bitcoinDashPrice.doubleValue*pow(10.0, self.bitcoinFormat.maximumFractionDigits),
    amt = [[self.bitcoinFormat numberFromString:string] doubleValue]*
    pow(10.0, self.bitcoinFormat.maximumFractionDigits);
    int64_t local = amt + DBL_EPSILON*amt, overflowbits = 0;
    
    if (local == 0) return 0;
    while (llabs(local) + 1 > INT64_MAX/DUFFS) local /= 2, overflowbits++; // make sure we won't overflow an int64_t
    int64_t min = llabs(local)*DUFFS/(int64_t)(price + DBL_EPSILON*price) + 1,
    max = (llabs(local) + 1)*DUFFS/(int64_t)(price + DBL_EPSILON*price) - 1,
    amount = (min + max)/2, p = 10;
    
    while (overflowbits > 0) local *= 2, min *= 2, max *= 2, amount *= 2, overflowbits--;
    
    if (amount >= MAX_MONEY) return (local < 0) ? -MAX_MONEY : MAX_MONEY;
    while ((amount/p)*p >= min && p <= INT64_MAX/10) p *= 10; // lowest decimal precision matching local currency string
    p /= 10;
    return (local < 0) ? -(amount/p)*p : (amount/p)*p;
}

-(NSString *)bitcoinCurrencyStringForAmount:(int64_t)amount
{
    if (amount == 0) return [self.bitcoinFormat stringFromNumber:@(0)];
    
    
    NSDecimalNumber *n = [[[NSDecimalNumber decimalNumberWithDecimal:self.bitcoinDashPrice.decimalValue]
                           decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithLongLong:llabs(amount)]]
                          decimalNumberByDividingBy:(id)[NSDecimalNumber numberWithLongLong:DUFFS]],
    *min = [[NSDecimalNumber one]
            decimalNumberByMultiplyingByPowerOf10:-self.bitcoinFormat.maximumFractionDigits];
    
    // if the amount is too small to be represented in local currency (but is != 0) then return a string like "$0.01"
    if ([n compare:min] == NSOrderedAscending) n = min;
    if (amount < 0) n = [n decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithInt:-1]];
    return [self.bitcoinFormat stringFromNumber:n];
}

- (NSString *)localCurrencyStringForDashAmount:(int64_t)amount
{
    NSNumber *n = [self localCurrencyNumberForDashAmount:amount];
    if (!n) {
        return NSLocalizedString(@"Updating Price",@"Updating Price");
    }
    return [self.localFormat stringFromNumber:n];
}

- (NSString *)localCurrencyStringForBitcoinAmount:(int64_t)amount
{
    if (amount == 0) return [self.localFormat stringFromNumber:@(0)];
    if (self.localCurrencyBitcoinPrice.doubleValue <= DBL_EPSILON) return @""; // no exchange rate data
    
    NSDecimalNumber *n = [[[NSDecimalNumber decimalNumberWithDecimal:self.localCurrencyBitcoinPrice.decimalValue]
                           decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithLongLong:llabs(amount)]]
                          decimalNumberByDividingBy:(id)[NSDecimalNumber numberWithLongLong:DUFFS]],
    *min = [[NSDecimalNumber one]
            decimalNumberByMultiplyingByPowerOf10:-self.localFormat.maximumFractionDigits];
    
    // if the amount is too small to be represented in local currency (but is != 0) then return a string like "$0.01"
    if ([n compare:min] == NSOrderedAscending) n = min;
    if (amount < 0) n = [n decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithInt:-1]];
    return [self.localFormat stringFromNumber:n];
}

- (NSNumber * _Nullable)localCurrencyNumberForDashAmount:(int64_t)amount {
    if (amount == 0) {
        return @0;
    }
    
    if (!self.localCurrencyBitcoinPrice || !self.bitcoinDashPrice) {
        return nil;
    }
    
    NSNumber *local = [NSNumber numberWithDouble:self.localCurrencyBitcoinPrice.doubleValue*self.bitcoinDashPrice.doubleValue];
    
    NSDecimalNumber *n = [[[NSDecimalNumber decimalNumberWithDecimal:local.decimalValue]
                           decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithLongLong:llabs(amount)]]
                          decimalNumberByDividingBy:(id)[NSDecimalNumber numberWithLongLong:DUFFS]],
    *min = [[NSDecimalNumber one]
            decimalNumberByMultiplyingByPowerOf10:-self.localFormat.maximumFractionDigits];
    
    // if the amount is too small to be represented in local currency (but is != 0) then return a string like "$0.01"
    if ([n compare:min] == NSOrderedAscending) n = min;
    if (amount < 0) n = [n decimalNumberByMultiplyingBy:(id)[NSDecimalNumber numberWithInt:-1]];
    return n;
}

// MARK: - UITextFieldDelegate

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string
{
    if (textField == self.pinField) {
        NSString * currentPin = [textField.text stringByReplacingCharactersInRange:range withString:string];
        NSUInteger l = currentPin.length;
        
        self.pinAlertController.title = [NSString stringWithFormat:@"%@\t%@\t%@\t%@%@", (l > 0 ? DOT : CIRCLE),
                                         (l > 1 ? DOT : CIRCLE), (l > 2 ? DOT : CIRCLE), (l > 3 ? DOT : CIRCLE),
                                         [self.pinAlertController.title substringFromIndex:7]];
        
        if (currentPin.length == 4) {
            
            BOOL verified = self.pinVerificationBlock(currentPin,self);
            self.pinField.delegate = nil;
            self.pinField.text = @"";
            self.pinField.delegate = self;
            if (verified) {
                return NO;
            } else {
                self.pinAlertController.title = [NSString stringWithFormat:CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"\t" CIRCLE @"%@",
                                                 [self.pinAlertController.title substringFromIndex:7]];
            }
        }
    }
    return YES;
}

-(BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (!textField.secureTextEntry) { //not the pin
        @autoreleasepool { // @autoreleasepool ensures sensitive data will be dealocated immediately
            NSString *phrase = [self.mnemonic cleanupPhrase:textField.text];
            
            if (! [phrase isEqual:textField.text]) textField.text = phrase;
            NSData * oldData = getKeychainData(MASTER_PUBKEY_KEY_BIP44, nil);
            NSData * seed = [self.mnemonic deriveKeyFromPhrase:[self.mnemonic
                                                                normalizePhrase:phrase] withPassphrase:nil];
            if (self.extendedBIP44PublicKey && ![[self.sequence extendedPublicKeyForAccount:0 fromSeed:seed purpose:BIP44_PURPOSE] isEqual:self.extendedBIP44PublicKey]) {
                self.resetAlertController.title = NSLocalizedString(@"recovery phrase doesn't match", nil);
                [self.resetAlertController performSelector:@selector(setTitle:)
                                                withObject:NSLocalizedString(@"recovery phrase", nil) afterDelay:3.0];
            } else if (oldData && ![[self.sequence deprecatedIncorrectExtendedPublicKeyForAccount:0 fromSeed:seed purpose:BIP44_PURPOSE] isEqual:oldData]) {
                self.resetAlertController.title = NSLocalizedString(@"recovery phrase doesn't match", nil);
                [self.resetAlertController performSelector:@selector(setTitle:)
                                                withObject:NSLocalizedString(@"recovery phrase", nil) afterDelay:3.0];
            }
            else {
                if (oldData) {
                    NSData *masterPubKeyBIP44 = [self.sequence extendedPublicKeyForAccount:0 fromSeed:seed purpose:BIP44_PURPOSE];
                    NSData *masterPubKeyBIP32 = [self.sequence extendedPublicKeyForAccount:0 fromSeed:seed purpose:BIP32_PURPOSE];
                    BOOL failed = !setKeychainData(masterPubKeyBIP44, EXTENDED_0_PUBKEY_KEY_BIP44, NO); //new keys
                    failed = failed | !setKeychainData(masterPubKeyBIP32, EXTENDED_0_PUBKEY_KEY_BIP32, NO); //new keys
                    failed = failed | !setKeychainData(nil, MASTER_PUBKEY_KEY_BIP44, NO); //old keys
                    failed = failed | !setKeychainData(nil, MASTER_PUBKEY_KEY_BIP32, NO); //old keys
                }
                setKeychainData(nil, SPEND_LIMIT_KEY, NO);
                setKeychainData(nil, PIN_KEY, NO);
                setKeychainData(nil, PIN_FAIL_COUNT_KEY, NO);
                setKeychainData(nil, PIN_FAIL_HEIGHT_KEY, NO);
                [self.resetAlertController dismissViewControllerAnimated:TRUE completion:^{
                    self.pinAlertController = nil;
                    [self setBrandNewPinWithCompletion:nil];
                }];
            }
        }
    }
    return TRUE;
}

@end
