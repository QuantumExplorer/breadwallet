//
//  BRBIP32Sequence.m
//  DashWallet
//
//  Created by Aaron Voisine on 7/19/13.
//  Copyright (c) 2013 Aaron Voisine <voisine@gmail.com>
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

#import "BRBIP32Sequence.h"
#import "BRKey.h"
#import "NSString+Dash.h"
#import "NSData+Dash.h"
#import "NSMutableData+Bitcoin.h"
#import <CommonCrypto/CommonHMAC.h>

#define BIP32_HARD     0x80000000u //not sure about this one
#define BIP32_SEED_KEY "Bitcoin seed"
#define BIP32_XPRV     "\x02\xFE\x52\xCC" //// Dash BIP32 prvkeys start with 'drkp'
#define BIP32_XPUB     "\x02\xFE\x52\xF8" //// Dash BIP32 pubkeys start with 'drkv'

// BIP32 is a scheme for deriving chains of addresses from a seed value
// https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki

// Private parent key -> private child key
//
// CKDpriv((kpar, cpar), i) -> (ki, ci) computes a child extended private key from the parent extended private key:
//
// - Check whether i >= 2^31 (whether the child is a hardened key).
//     - If so (hardened child): let I = HMAC-SHA512(Key = cpar, Data = 0x00 || ser256(kpar) || ser32(i)).
//       (Note: The 0x00 pads the private key to make it 33 bytes long.)
//     - If not (normal child): let I = HMAC-SHA512(Key = cpar, Data = serP(point(kpar)) || ser32(i)).
// - Split I into two 32-byte sequences, IL and IR.
// - The returned child key ki is parse256(IL) + kpar (mod n).
// - The returned chain code ci is IR.
// - In case parse256(IL) >= n or ki = 0, the resulting key is invalid, and one should proceed with the next value for i
//   (Note: this has probability lower than 1 in 2^127.)
//
static void CKDpriv(NSMutableData *k, NSMutableData *c, uint32_t i)
{
    NSMutableData *I = [NSMutableData secureDataWithLength:CC_SHA512_DIGEST_LENGTH];
    NSMutableData *d = [NSMutableData secureDataWithCapacity:33 + sizeof(i)];
    
    if (i & BIP32_HARD) {
        d.length = 33 - k.length;
        [d appendData:k];
    }
    else [d setData:[[BRKey keyWithSecret:k compressed:YES] publicKey]];

    i = CFSwapInt32HostToBig(i);
    [d appendBytes:&i length:sizeof(i)];

    CCHmac(kCCHmacAlgSHA512, c.bytes, c.length, d.bytes, d.length, I.mutableBytes); // I = HMAC-SHA512(c, k|P(k) || i)
    
    secp256k1_mod_add(k.mutableBytes, I.bytes, k.bytes); // k = IL + k (mod n)
    
    [c replaceBytesInRange:NSMakeRange(0, c.length) withBytes:(const unsigned char *)I.bytes + 32 length:32]; // c = IR    
}

// Public parent key -> public child key
//
// CKDpub((Kpar, cpar), i) -> (Ki, ci) computes a child extended public key from the parent extended public key.
// It is only defined for non-hardened child keys.
//
// - Check whether i >= 2^31 (whether the child is a hardened key).
//     - If so (hardened child): return failure
//     - If not (normal child): let I = HMAC-SHA512(Key = cpar, Data = serP(Kpar) || ser32(i)).
// - Split I into two 32-byte sequences, IL and IR.
// - The returned child key Ki is point(parse256(IL)) + Kpar.
// - The returned chain code ci is IR.
// - In case parse256(IL) >= n or Ki is the point at infinity, the resulting key is invalid, and one should proceed with
//   the next value for i.
//
static void CKDpub(NSMutableData *K, NSMutableData *c, uint32_t i)
{
    if (i & BIP32_HARD) {
        @throw [NSException exceptionWithName:@"BRBIP32SequenceCKDPubException"
                reason:@"can't derive private child key from public parent key" userInfo:nil];
    }

    NSMutableData *I = [NSMutableData secureDataWithLength:CC_SHA512_DIGEST_LENGTH],
                  *d = [NSMutableData secureDataWithData:K];
    
    i = CFSwapInt32HostToBig(i);
    [d appendBytes:&i length:sizeof(i)];

    CCHmac(kCCHmacAlgSHA512, c.bytes, c.length, d.bytes, d.length, I.mutableBytes); // I = HMAC-SHA512(c, P(K) || i)
    
    [c replaceBytesInRange:NSMakeRange(0, c.length) withBytes:(const uint8_t *)I.bytes + 32 length:32]; // c = IR
    I.length = 32;

    NSData *pIL = [[BRKey keyWithSecret:I compressed:YES] publicKey];

    secp256k1_point_add(K.mutableBytes, pIL.bytes, K.bytes, YES); // K = P(IL) + K
}

// helper function for serializing BIP32 master public/private keys to standard export format
static NSString *serialize(uint8_t depth, uint32_t fingerprint, uint32_t child, NSData *chain, NSData *key)
{
    NSMutableData *d = [NSMutableData secureDataWithCapacity:14 + key.length + chain.length];

    fingerprint = CFSwapInt32HostToBig(fingerprint);
    child = CFSwapInt32HostToBig(child);

    [d appendBytes:key.length < 33 ? BIP32_XPRV : BIP32_XPUB length:4];
    [d appendBytes:&depth length:1];
    [d appendBytes:&fingerprint length:sizeof(fingerprint)];
    [d appendBytes:&child length:sizeof(child)];
    [d appendData:chain];
    if (key.length < 33) [d appendBytes:"\0" length:1];
    [d appendData:key];

    return [NSString base58checkWithData:d];
}

@implementation BRBIP32Sequence

#pragma mark - BRKeySequence

// master public key format is: 4 byte parent fingerprint || 32 byte chain code || 33 byte compressed public key
// the values are taken from BIP32 account m/0H
- (NSData *)masterPublicKeyFromSeed:(NSData *)seed
{
    if (! seed) return nil;

    NSMutableData *mpk = [NSMutableData secureData];
    NSMutableData *I = [NSMutableData secureDataWithLength:CC_SHA512_DIGEST_LENGTH];
    NSMutableData *secret = [NSMutableData secureDataWithCapacity:32];
    NSMutableData *chain = [NSMutableData secureDataWithCapacity:32];

    CCHmac(kCCHmacAlgSHA512, BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length, I.mutableBytes);

    [secret appendBytes:I.bytes length:32];
    [chain appendBytes:(const unsigned char *)I.bytes + 32 length:32];
    [mpk appendBytes:[[[BRKey keyWithSecret:secret compressed:YES] hash160] bytes] length:4];
    
    CKDpriv(secret, chain, 0 | BIP32_HARD); // account 0H

    [mpk appendData:chain];
    [mpk appendData:[[BRKey keyWithSecret:secret compressed:YES] publicKey]];

    return mpk;
}

- (NSData *)publicKey:(unsigned)n internal:(BOOL)internal masterPublicKey:(NSData *)masterPublicKey
{
    if (masterPublicKey.length < 36) return nil;

    NSMutableData *chain = [NSMutableData secureDataWithCapacity:32];
    NSMutableData *pubKey = [NSMutableData secureDataWithCapacity:65];

    [chain appendBytes:(const unsigned char *)masterPublicKey.bytes + 4 length:32];
    [pubKey appendBytes:(const unsigned char *)masterPublicKey.bytes + 36 length:masterPublicKey.length - 36];

    CKDpub(pubKey, chain, internal ? 1 : 0); // internal or external chain
    CKDpub(pubKey, chain, n); // nth key in chain

    return pubKey;
}

- (NSString *)privateKey:(unsigned)n internal:(BOOL)internal fromSeed:(NSData *)seed
{
    return seed ? [[self privateKeys:@[@(n)] internal:internal fromSeed:seed] lastObject] : nil;
}

- (NSArray *)privateKeys:(NSArray *)n internal:(BOOL)internal fromSeed:(NSData *)seed
{
    if (! seed || ! n) return nil;
    if (n.count == 0) return @[];

    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n.count];
    NSMutableData *I = [NSMutableData secureDataWithLength:CC_SHA512_DIGEST_LENGTH];
    NSMutableData *secret = [NSMutableData secureDataWithCapacity:32];
    NSMutableData *chain = [NSMutableData secureDataWithCapacity:32];
    uint8_t version = DASH_PRIVKEY;

#if DASH_TESTNET
    version = DASH_PRIVKEY_TEST;
#endif

    CCHmac(kCCHmacAlgSHA512, BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length, I.mutableBytes);
    
    [secret appendBytes:I.bytes length:32];
    [chain appendBytes:(const unsigned char *)I.bytes + 32 length:32];

    CKDpriv(secret, chain, 0 | BIP32_HARD); // account 0H
    CKDpriv(secret, chain, internal ? 1 : 0); // internal or external chain

    for (NSNumber *i in n) {
        NSMutableData *prvKey = [NSMutableData secureDataWithCapacity:34];
        NSMutableData *s = [NSMutableData secureDataWithData:secret];
        NSMutableData *c = [NSMutableData secureDataWithData:chain];
        
        CKDpriv(s, c, i.unsignedIntValue); // nth key in chain

        [prvKey appendBytes:&version length:1];
        [prvKey appendData:s];
        [prvKey appendBytes:"\x01" length:1]; // specifies compressed pubkey format
        [a addObject:[NSString base58checkWithData:prvKey]];
    }

    return a;
}

#pragma mark - serializations

- (NSString *)serializedPrivateMasterFromSeed:(NSData *)seed
{
    if (! seed) return nil;

    NSMutableData *I = [NSMutableData secureDataWithLength:CC_SHA512_DIGEST_LENGTH];

    CCHmac(kCCHmacAlgSHA512, BIP32_SEED_KEY, strlen(BIP32_SEED_KEY), seed.bytes, seed.length, I.mutableBytes);
    
    NSData *secret = [NSData dataWithBytesNoCopy:I.mutableBytes length:32 freeWhenDone:NO];
    NSData *chain = [NSData dataWithBytesNoCopy:(unsigned char *)I.mutableBytes + 32 length:32 freeWhenDone:NO];

    return serialize(0, 0, 0, chain, secret);
}

- (NSString *)serializedMasterPublicKey:(NSData *)masterPublicKey
{
    if (masterPublicKey.length < 36) return nil;
    
    uint32_t fingerprint = CFSwapInt32BigToHost(*(const uint32_t *)masterPublicKey.bytes);
    NSData *chain = [NSData dataWithBytesNoCopy:(unsigned char *)masterPublicKey.bytes + 4 length:32 freeWhenDone:NO];
    NSData *pubKey = [NSData dataWithBytesNoCopy:(unsigned char *)masterPublicKey.bytes + 36
                      length:masterPublicKey.length - 36 freeWhenDone:NO];

    return serialize(1, fingerprint, 0 | BIP32_HARD, chain, pubKey);
}

@end
