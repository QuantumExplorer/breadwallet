//
//  BRQRScanViewModel.m
//  dashwallet
//
//  Created by Andrew Podkovyrin on 21/12/2017.
//  Copyright © 2017 Aaron Voisine. All rights reserved.
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

#import <AVFoundation/AVFoundation.h>

#import "NSString+Dash.h"
#import "BREventManager.h"
#import "BRPaymentRequest.h"

#import "BRQRScanViewModel.h"

static NSTimeInterval const kReqeustTimeout = 5.0;
static NSTimeInterval const kResumeSearchTimeInterval = 1.0;

#pragma - QR Object

@interface QRCodeObject ()

@property (assign, nonatomic) QRCodeObjectType type;
@property (copy, nonatomic) NSString *errorMessage;

@end

@implementation QRCodeObject

- (instancetype)initWithMetadataObject:(AVMetadataMachineReadableCodeObject *)metadataObject {
    self = [super init];
    if (self) {
        _metadataObject = metadataObject;
    }
    return self;
}

- (void)setValid {
    self.errorMessage = nil;
    self.type = QRCodeObjectTypeValid;
}

- (void)setInvalidWithErrorMessage:(NSString *)errorMessage {
    self.errorMessage = errorMessage;
    self.type = QRCodeObjectTypeInvalid;
}

@end

#pragma mark - View Model

@interface BRQRScanViewModel () <AVCaptureMetadataOutputObjectsDelegate>

@property (strong, nonatomic) dispatch_queue_t sessionQueue;
@property (strong, nonatomic) dispatch_queue_t metadataQueue;
@property (assign, nonatomic, getter=isCaptureSessionConfigured) BOOL captureSessionConfigured;
@property (assign, atomic) BOOL paused;
@property (strong, nonatomic) QRCodeObject *qrCodeObject;

@end

@implementation BRQRScanViewModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _captureSession = [[AVCaptureSession alloc] init];
    }
    return self;
}

+ (BOOL)isTorchAvailable {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    return device.torchAvailable;
}

- (BOOL)isCameraDeniedOrRestricted {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted);
}

- (void)startPreview {
    void (^doStartPreview)(void) = ^{
#if !TARGET_OS_SIMULATOR
        [self setupCaptureSessionIfNeeded];
#endif /* TARGET_OS_SIMULATOR */
        
        dispatch_async(self.sessionQueue, ^{
            if (!self.captureSession.isRunning) {
                [self.captureSession startRunning];
            }
        });
    };
    
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]) {
        case AVAuthorizationStatusNotDetermined: {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                                         if (granted) {
                                             dispatch_async(dispatch_get_main_queue(), doStartPreview);
                                         }
                                     }];
            break;
        }
            
        case AVAuthorizationStatusRestricted:
        case AVAuthorizationStatusDenied: {
            break;
        }
            
        case AVAuthorizationStatusAuthorized: {
            doStartPreview();
            break;
        }
    }
}

- (void)stopPreview {
    dispatch_async(self.sessionQueue, ^{
        if (self.captureSession.isRunning) {
            [self.captureSession stopRunning];
        }
    });
}

- (void)switchTorch {
    if (![[self class] isTorchAvailable]) {
        return;
    }
    
    if (!self.captureSession.isRunning) {
        return;
    }
    
    dispatch_async(self.sessionQueue, ^{
        NSError *error = nil;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        
        if ([device lockForConfiguration:&error]) {
            device.torchMode = device.torchActive ? AVCaptureTorchModeOff : AVCaptureTorchModeOn;
            [device unlockForConfiguration];
        }
        else {
#ifdef DEBUG
            NSLog(@"BRQRScanViewModel: %@", error);
#endif /* DEBUG */
        }
    });
}

- (void)cancel {
    [self.delegate qrScanViewModelDidCancel:self];
}

#pragma mark Private

- (dispatch_queue_t)sessionQueue {
    if (!_sessionQueue) {
        _sessionQueue = dispatch_queue_create("BRQRScanViewModel.CaptureSession.queue", DISPATCH_QUEUE_SERIAL);
    }
    return _sessionQueue;
}

- (dispatch_queue_t)metadataQueue {
    if (!_metadataQueue) {
        _metadataQueue = dispatch_queue_create("BRQRScanViewModel.CaptureMetadataOutput.queue", DISPATCH_QUEUE_SERIAL);
    }
    return _metadataQueue;
}

- (void)setupCaptureSessionIfNeeded {
    if (self.isCaptureSessionConfigured) {
        return;
    }
    self.captureSessionConfigured = YES;
    
    dispatch_async(self.sessionQueue, ^{
        NSError *error = nil;
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (error) {
#ifdef DEBUG
            NSLog(@"BRQRScanViewModel: %@", error);
#endif /* DEBUG */
        }
        if ([device lockForConfiguration:&error]) {
            if (device.isAutoFocusRangeRestrictionSupported) {
                device.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNear;
            }
            
            if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            }
            
            [device unlockForConfiguration];
        }
        else {
#ifdef DEBUG
            NSLog(@"BRQRScanViewModel: %@", error);
#endif /* DEBUG */
        }
        
        [self.captureSession beginConfiguration];
        
        if (input && [self.captureSession canAddInput:input]) {
            [self.captureSession addInput:input];
        }
        
        AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
        if ([self.captureSession canAddOutput:output]) {
            [self.captureSession addOutput:output];
        }
        [output setMetadataObjectsDelegate:self queue:self.metadataQueue];
        if ([output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode]) {
            output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
        }
        
        [self.captureSession commitConfiguration];
    });
}

- (void)pauseQRCodeSearch {
    self.paused = YES;
}

- (void)resumeQRCodeSearch {
    NSAssert([NSThread isMainThread], nil);
    self.paused = NO;
    self.qrCodeObject = nil;
}

#pragma mark AVCaptureMetadataOutputObjectsDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if (self.paused) {
        return;
    }
    
    NSUInteger index = [metadataObjects indexOfObjectPassingTest:^BOOL(__kindof AVMetadataObject * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        return [obj.type isEqual:AVMetadataObjectTypeQRCode];
    }];
    if (index == NSNotFound) {
        return;
    }
    
    [self pauseQRCodeSearch];
    
    [BREventManager saveEvent:@"send:scanned_qr"];
    
    AVMetadataMachineReadableCodeObject *codeObject = metadataObjects[index];
    
    NSAssert(![NSThread isMainThread], nil);
    dispatch_sync(dispatch_get_main_queue(), ^{ // sync!
        self.qrCodeObject = [[QRCodeObject alloc] initWithMetadataObject:codeObject];
    });
    
    NSString *addr = [codeObject.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BRPaymentRequest *request = [BRPaymentRequest requestWithString:addr];
    if (request.isValid || [addr isValidBitcoinPrivateKey] || [addr isValidDashPrivateKey] || [addr isValidDashBIP38Key]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ // sync!
            [self.qrCodeObject setValid];
        });
        
        [BREventManager saveEvent:@"send:valid_qr_scan"];
        
        if (request.r.length > 0) { // start fetching payment protocol request right away
            __weak __typeof__(self) weakSelf = self;
            [BRPaymentRequest fetch:request.r scheme:request.scheme timeout:kReqeustTimeout
                         completion:^(BRPaymentProtocolRequest *req, NSError *error) {
                             dispatch_async(dispatch_get_main_queue(), ^{
                                 __strong __typeof__(weakSelf) strongSelf = weakSelf;
                                 [strongSelf.delegate qrScanViewModel:strongSelf
                                                didScanPaymentRequest:request
                                                      protocolRequest:req
                                                                error:error];
                             });
                         }];
        }
        else { // standard non payment protocol request
            [self.delegate qrScanViewModel:self didScanStandardNonPaymentRequest:request];            
        }
    } else {
        __weak __typeof__(self) weakSelf = self;
        [BRPaymentRequest fetch:request.r scheme:request.scheme timeout:kReqeustTimeout
                     completion:^(BRPaymentProtocolRequest *req, NSError *error) { // check to see if it's a BIP73 url
                         dispatch_async(dispatch_get_main_queue(), ^{
                             __strong __typeof__(weakSelf) strongSelf = weakSelf;
                             
                             if (req) {
                                 [strongSelf.qrCodeObject setValid];
                                 [strongSelf.delegate qrScanViewModel:strongSelf didScanBIP73PaymentProtocolRequest:req];
                             }
                             else {
                                 NSString *errorMessage = nil;
                                 if (([request.scheme isEqual:@"dash"] && request.paymentAddress.length > 1) ||
                                     [request.paymentAddress hasPrefix:@"X"] || [request.paymentAddress hasPrefix:@"7"]) {
                                     errorMessage = [NSString stringWithFormat:@"%@:\n%@",
                                                     NSLocalizedString(@"not a valid dash address", nil),
                                                     request.paymentAddress];
                                 } else if (([request.scheme isEqual:@"bitcoin"] && request.paymentAddress.length > 1) ||
                                            [request.paymentAddress hasPrefix:@"1"] || [request.paymentAddress hasPrefix:@"3"]) {
                                     errorMessage = [NSString stringWithFormat:@"%@:\n%@",
                                                     NSLocalizedString(@"not a valid bitcoin address", nil),
                                                     request.paymentAddress];
                                 }
                                 else {
                                     errorMessage = NSLocalizedString(@"not a dash or bitcoin QR code", nil);
                                 }
                                 [strongSelf.qrCodeObject setInvalidWithErrorMessage:errorMessage];
                                 
                                 [strongSelf performSelector:@selector(resumeQRCodeSearch) withObject:nil afterDelay:kResumeSearchTimeInterval];
                                 
                                 [BREventManager saveEvent:@"send:unsuccessful_bip73"];
                             }
                         });
                     }];
    }
}

@end
