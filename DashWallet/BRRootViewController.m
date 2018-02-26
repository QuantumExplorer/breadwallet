//
//  BRRootViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 9/15/13.
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

#import "BRRootViewController.h"
#import "BRReceiveViewController.h"
#import "BRSendViewController.h"
#import "BRSettingsViewController.h"
#import "BRTxHistoryViewController.h"
#import "BRRestoreViewController.h"
#import "BRSeedViewController.h"
#import "BRAppDelegate.h"
#import "BRBubbleView.h"
#import "BRBouncyBurgerButton.h"
#import "BRPeerManager.h"
#import "BRWalletManager.h"
#import "BRPaymentRequest.h"
#import "UIImage+Utils.h"
#import "BREventManager.h"
#import "BREventConfirmView.h"
#import "Reachability.h"
#import "NSString+Dash.h"
#import <WebKit/WebKit.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <sys/stat.h>
#import <mach-o/dyld.h>

#define BALANCE_TIP_START NSLocalizedString(@"This is your $PAC balance.", nil)

#define BALANCE_TIP NSLocalizedString(@"This is your $PAC balance. $PAC is a currency. "\
"The exchange rate changes with the market.", nil)
#define MDASH_TIP    NSLocalizedString(@"%@ is for 'mDASH'. %@ = 1 DASH.", nil)

#define BACKUP_DIALOG_TIME_KEY @"BACKUP_DIALOG_TIME"
#define BALANCE_KEY            @"BALANCE"

@interface BRRootViewController ()

@property (nonatomic, strong) IBOutlet UIProgressView *progress, *pulse;
@property (nonatomic, strong) IBOutlet UIView *errorBar, *splash, *logo, *blur;
@property (nonatomic, strong) IBOutlet UIGestureRecognizer *navBarTap;
@property (nonatomic, strong) IBOutlet UIBarButtonItem *lock;
@property (nonatomic, strong) IBOutlet BRBouncyBurgerButton *burger;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *wallpaperXLeft;

@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) BRBubbleView *tipView;
@property (nonatomic, assign) BOOL shouldShowTips, showTips, inNextTip, didAppear;
@property (nonatomic, assign) uint64_t balance;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSData *file;
@property (nonatomic, strong) Reachability *reachability;
@property (nonatomic, strong) id urlObserver, fileObserver, protectedObserver, balanceObserver, seedObserver;
@property (nonatomic, strong) id reachabilityObserver, syncStartedObserver, syncFinishedObserver, syncFailedObserver;
@property (nonatomic, strong) id activeObserver, resignActiveObserver, foregroundObserver, backgroundObserver;
@property (nonatomic, assign) NSTimeInterval timeout, start;
@property (nonatomic, assign) SystemSoundID pingsound;

@end

@implementation BRRootViewController

-(BOOL)prefersStatusBarHidden {
    return NO;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    // Do any additional setup after loading the view.
    
    // detect jailbreak so we can throw up an idiot warning, in viewDidLoad so it can't easily be swizzled out
    struct stat s;
    BOOL jailbroken = (stat("/bin/sh", &s) == 0) ? YES : NO; // if we can see /bin/sh, the app isn't sandboxed
    
    // some anti-jailbreak detection tools re-sandbox apps, so do a secondary check for any MobileSubstrate dyld images
    for (uint32_t count = _dyld_image_count(), i = 0; i < count && ! jailbroken; i++) {
        if (strstr(_dyld_get_image_name(i), "MobileSubstrate")) jailbroken = YES;
    }
    
#if TARGET_IPHONE_SIMULATOR
    jailbroken = NO;
#endif
    
    _balance = UINT64_MAX;
    
    self.receiveViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"ReceiveViewController"];
    self.sendViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"SendViewController"];
    self.pageViewController = [self.storyboard instantiateViewControllerWithIdentifier:@"PageViewController"];
    
    self.pageViewController.dataSource = self;
    [self.pageViewController setViewControllers:@[self.sendViewController]
                                      direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
    self.pageViewController.view.frame = self.view.bounds;
    [self addChildViewController:self.pageViewController];
    [self.view insertSubview:self.pageViewController.view belowSubview:self.splash];
    [self.pageViewController didMoveToParentViewController:self];
    
    self.shouldShowTips = TRUE;
    
    for (UIView *view in self.pageViewController.view.subviews) {
        if (! [view isKindOfClass:[UIScrollView class]]) continue;
        self.scrollView = (id)view;
        self.scrollView.delegate = self;
        break;
    }
    
    if (!self.errorBar.superview) {
        [self.navigationController.navigationBar addSubview:self.errorBar];
        [self.navigationController.navigationBar addConstraint:[NSLayoutConstraint constraintWithItem:self.errorBar attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:self.navigationController.navigationBar attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0]];
        [self.navigationController.navigationBar addConstraint:[NSLayoutConstraint constraintWithItem:self.errorBar attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:self.navigationController.navigationBar attribute:NSLayoutAttributeRight multiplier:1.0 constant:0.0]];
        [self.navigationController.navigationBar addConstraint:[NSLayoutConstraint constraintWithItem:self.errorBar attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.navigationController.navigationBar attribute:NSLayoutAttributeBottom multiplier:1.0 constant:-48.0]];
    }
    
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    self.urlObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRURLNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      if (! manager.noWallet) {
                                                          if (self.navigationController.topViewController != self) {
                                                              [self.navigationController popToRootViewControllerAnimated:YES];
                                                          }
                                                          
                                                          if (self.navigationController.presentedViewController) {
                                                              [self.navigationController dismissViewControllerAnimated:YES completion:nil];
                                                          }
                                                          
                                                          NSURL * url = note.userInfo[@"url"];
                                                          
                                                          
                                                          
                                                          
                                                          BRSendViewController *c = self.sendViewController;
                                                          
                                                          [self.pageViewController setViewControllers:(c ? @[c] : @[])
                                                                                            direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:^(BOOL finished) {
                                                                                                _url = note.userInfo[@"url"];
                                                                                                
                                                                                                if (self.didAppear && [UIApplication sharedApplication].protectedDataAvailable) {
                                                                                                    _url = nil;
                                                                                                    [c performSelector:@selector(handleURL:) withObject:note.userInfo[@"url"] afterDelay:0.0];
                                                                                                }
                                                                                            }];
                                                          
                                                      }
                                                  }];
    
    self.fileObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRFileNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      if (! manager.noWallet) {
                                                          if (self.navigationController.topViewController != self) {
                                                              [self.navigationController popToRootViewControllerAnimated:YES];
                                                          }
                                                          
                                                          if (self.navigationController.presentedViewController) {
                                                              [self.navigationController dismissViewControllerAnimated:YES completion:nil];
                                                          }
                                                          
                                                          BRSendViewController *sendController = self.sendViewController;
                                                          
                                                          [self.pageViewController setViewControllers:(sendController ? @[sendController] : @[])
                                                                                            direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:^(BOOL finished) {
                                                                                                _file = note.userInfo[@"file"];
                                                                                                
                                                                                                if (self.didAppear && [UIApplication sharedApplication].protectedDataAvailable) {
                                                                                                    _file = nil;
                                                                                                    [sendController handleFile:note.userInfo[@"file"]];
                                                                                                }
                                                                                            }];
                                                      }
                                                  }];
    
    self.foregroundObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           if (! manager.noWallet) {
                                                               BREventManager *eventMan = [BREventManager sharedEventManager];
                                                               
                                                               [[BRPeerManager sharedInstance] connect];
                                                               [self.sendViewController updateClipboardText];
                                                               
                                                               if (eventMan.isInSampleGroup && ! eventMan.hasAskedForPermission) {
                                                                   [eventMan acquireUserPermissionInViewController:self.navigationController withCallback:nil];
                                                               }
                                                               else {
                                                                   NSString *userDefaultsKey = @"has_asked_for_push";
                                                                   [[NSUserDefaults standardUserDefaults] setBool:TRUE forKey:userDefaultsKey];
                                                                   ([(id)[UIApplication sharedApplication].delegate registerForPushNotifications]);
                                                               }
                                                           }
                                                           
                                                           if (jailbroken && manager.wallet.totalReceived > 0) {
                                                               UIAlertController * alert = [UIAlertController
                                                                                            alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                                                                            message:NSLocalizedString(@"DEVICE SECURITY COMPROMISED\n"
                                                                                                                      "Any 'jailbreak' app can access any other app's keychain data "
                                                                                                                      "(and steal your dash). "
                                                                                                                      "Wipe this wallet immediately and restore on a secure device.", nil)
                                                                                            preferredStyle:UIAlertControllerStyleAlert];
                                                               UIAlertAction* ignoreButton = [UIAlertAction
                                                                                              actionWithTitle:NSLocalizedString(@"ignore", nil)
                                                                                              style:UIAlertActionStyleCancel
                                                                                              handler:^(UIAlertAction * action) {
                                                                                                  
                                                                                              }];
                                                               UIAlertAction* wipeButton = [UIAlertAction
                                                                                            actionWithTitle:NSLocalizedString(@"wipe", nil)
                                                                                            style:UIAlertActionStyleDestructive
                                                                                            handler:^(UIAlertAction * action) {
                                                                                                BRRestoreViewController *restoreController =
                                                                                                [self.storyboard instantiateViewControllerWithIdentifier:@"WipeViewController"];
                                                                                                
                                                                                                [self.navigationController pushViewController:restoreController animated:NO];
                                                                                            }];
                                                               
                                                               [alert addAction:ignoreButton];
                                                               [alert addAction:wipeButton];
                                                               [self presentViewController:alert animated:YES completion:nil];
                                                           }
                                                           else if (jailbroken) {
                                                               UIAlertController * alert = [UIAlertController
                                                                                            alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                                                                            message:NSLocalizedString(@"DEVICE SECURITY COMPROMISED\n"
                                                                                                                      "Any 'jailbreak' app can access any other app's keychain data "
                                                                                                                      "(and steal your dash).", nil)
                                                                                            preferredStyle:UIAlertControllerStyleAlert];
                                                               UIAlertAction* ignoreButton = [UIAlertAction
                                                                                              actionWithTitle:NSLocalizedString(@"ignore", nil)
                                                                                              style:UIAlertActionStyleCancel
                                                                                              handler:^(UIAlertAction * action) {
                                                                                                  
                                                                                              }];
                                                               UIAlertAction* closeButton = [UIAlertAction
                                                                                             actionWithTitle:NSLocalizedString(@"close app", nil)
                                                                                             style:UIAlertActionStyleDefault
                                                                                             handler:^(UIAlertAction * action) {
                                                                                                 exit(0);
                                                                                             }];
                                                               
                                                               [alert addAction:ignoreButton];
                                                               [alert addAction:closeButton];
                                                               [self presentViewController:alert animated:YES completion:nil];
                                                           }
                                                       }];
    
    self.backgroundObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           if (! manager.noWallet) { // lockdown the app
                                                               manager.didAuthenticate = NO;
                                                               self.navigationItem.titleView = self.logo;
                                                               self.navigationItem.leftBarButtonItem.image = [UIImage imageNamed:@"burger"];
                                                               self.navigationItem.rightBarButtonItem = self.lock;
                                                               self.pageViewController.view.alpha = 1.0;
                                                               [UIApplication sharedApplication].applicationIconBadgeNumber = 0; // reset app badge number
                                                           }
                                                       }];
    
    self.activeObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           [self.blur removeFromSuperview];
                                                           self.blur = nil;
                                                       }];
    
    self.resignActiveObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           UIView *keyWindow = [UIApplication sharedApplication].keyWindow;
                                                           UIImage *img;
                                                           
                                                           if (! [keyWindow viewWithTag:-411]) { // only take a screenshot if no views are marked highly sensitive
                                                               UIGraphicsBeginImageContext([UIScreen mainScreen].bounds.size);
                                                               [keyWindow drawViewHierarchyInRect:[UIScreen mainScreen].bounds afterScreenUpdates:NO];
                                                               img = UIGraphicsGetImageFromCurrentImageContext();
                                                               UIGraphicsEndImageContext();
                                                           }
                                                           else img = [UIImage imageNamed:@"wallpaper-default"];
                                                           
                                                           [self.blur removeFromSuperview];
                                                           self.blur = [[UIImageView alloc] initWithImage:[img blurWithRadius:3]];
                                                           [keyWindow.subviews.lastObject addSubview:self.blur];
                                                       }];
    
    self.reachabilityObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:kReachabilityChangedNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      if (! manager.noWallet && self.reachability.currentReachabilityStatus != NotReachable &&
                                                          [UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
                                                          [[BRPeerManager sharedInstance] connect];
                                                      }
                                                      else if (! manager.noWallet && self.reachability.currentReachabilityStatus == NotReachable) {
                                                          [self showErrorBar];
                                                      }
                                                  }];
    
    self.balanceObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletBalanceChangedNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
                                                      double progress = [BRPeerManager sharedInstance].syncProgress;
                                                      
                                                      if (_balance != UINT64_MAX && progress > DBL_EPSILON && progress + DBL_EPSILON < 1.0) { // wait for sync
                                                          self.balance = _balance; // this updates the local currency value with the latest exchange rate
                                                          return;
                                                      }
                                                      
                                                      [self showBackupDialogIfNeeded];
                                                      [self.receiveViewController updateAddress];
                                                      self.balance = manager.wallet.balance;
                                                  }];
    
    self.seedObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletManagerSeedChangedNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           [self.receiveViewController updateAddress];
                                                           self.balance = manager.wallet.balance;
                                                       }];
    
    self.syncStartedObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncStartedNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           if (self.reachability.currentReachabilityStatus == NotReachable) return;
                                                           [self hideErrorBarWithCompletion:nil];
                                                           [self startActivityWithTimeout:0];
                                                       }];
    
    self.syncFinishedObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFinishedNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           if (self.timeout < 1.0) [self stopActivityWithSuccess:YES];
                                                           [self showBackupDialogIfNeeded];
                                                           if (! self.shouldShowTips) [self hideTips];
                                                           self.shouldShowTips = YES;
                                                           if (! manager.didAuthenticate) self.navigationItem.titleView = self.logo;
                                                           [self.receiveViewController updateAddress];
                                                           self.balance = manager.wallet.balance;
                                                       }];
    
    self.syncFailedObserver =
    [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFailedNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *note) {
                                                           if (self.timeout < 1.0) [self stopActivityWithSuccess:YES];
                                                           [self showBackupDialogIfNeeded];
                                                           [self.receiveViewController updateAddress];
                                                           [self showErrorBar];
                                                       }];
    
    self.reachability = [Reachability reachabilityForInternetConnection];
    [self.reachability startNotifier];
    
    self.navigationController.delegate = self;
    
#if DASH_TESTNET
    UILabel *label = [UILabel new];
    
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightLight];
    label.textColor = [UIColor redColor];
    label.textAlignment = NSTextAlignmentRight;
    label.text = @"testnet";
    label.tag = 0xbeef;
    [label sizeToFit];
    label.center = CGPointMake(self.view.frame.size.width - label.frame.size.width,
                               self.view.frame.size.height - (label.frame.size.height + 5));
    [self.view addSubview:label];
#endif
    
#if SNAPSHOT
    [self.view viewWithTag:0xbeef].hidden = YES;
    [self.navigationController
     presentViewController:[self.storyboard instantiateViewControllerWithIdentifier:@"NewWalletNav"] animated:NO
     completion:^{
         [self.navigationController.presentedViewController.view
          addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nextScreen:)]];
     }];
#endif
    
    if (manager.watchOnly) { // watch only wallet
        UILabel *label = [UILabel new];
        
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = [UIColor redColor];
        label.textAlignment = NSTextAlignmentRight;
        label.text = @"watch only";
        [label sizeToFit];
        label.center = CGPointMake(self.view.frame.size.width - label.frame.size.width,
                                   self.view.frame.size.height - (label.frame.size.height + 5)*2);
        [self.view addSubview:label];
    }
    
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)[[NSBundle mainBundle] URLForResource:@"coinflip"
                                                                                withExtension:@"aiff"], &_pingsound);
    
    if (! manager.noWallet) {
        //TODO: do some kickass quick logo animation, fast circle spin that slows
        self.splash.hidden = YES;
        self.navigationController.navigationBar.hidden = NO;
    }
    
    if (jailbroken && manager.wallet.totalReceived + manager.wallet.totalSent > 0) {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                     message:NSLocalizedString(@"DEVICE SECURITY COMPROMISED\n"
                                                               "Any 'jailbreak' app can access any other app's keychain data "
                                                               "(and steal your dash). "
                                                               "Wipe this wallet immediately and restore on a secure device.", nil)
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* ignoreButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ignore", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
        UIAlertAction* wipeButton = [UIAlertAction
                                     actionWithTitle:NSLocalizedString(@"wipe", nil)
                                     style:UIAlertActionStyleDestructive
                                     handler:^(UIAlertAction * action) {
                                         BRRestoreViewController *restoreController =
                                         [self.storyboard instantiateViewControllerWithIdentifier:@"WipeViewController"];
                                         
                                         [self.navigationController pushViewController:restoreController animated:NO];
                                     }];
        
        [alert addAction:ignoreButton];
        [alert addAction:wipeButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
    else if (jailbroken) {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                     message:NSLocalizedString(@"DEVICE SECURITY COMPROMISED\n"
                                                               "Any 'jailbreak' app can access any other app's keychain data "
                                                               "(and steal your dash).", nil)
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* ignoreButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ignore", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           
                                       }];
        UIAlertAction* closeButton = [UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"close app", nil)
                                      style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction * action) {
                                          exit(0);
                                      }];
        
        [alert addAction:ignoreButton];
        [alert addAction:closeButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    self.navigationItem.leftBarButtonItem.image = [UIImage imageNamed:@"burger"];
    self.pageViewController.view.alpha = 1.0;
    if ([BRWalletManager sharedInstance].didAuthenticate) [self unlock:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    self.didAppear = YES;
    
    if (! self.navBarTap) {
        self.navBarTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(navBarTap:)];
        self.navBarTap.delegate = self;
        [self.navigationController.navigationBar addGestureRecognizer:self.navBarTap];
    }
    
    if (! self.protectedObserver) {
        self.protectedObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationProtectedDataDidBecomeAvailable
                                                          object:nil queue:nil usingBlock:^(NSNotification *note) {
                                                              [self performSelector:@selector(protectedViewDidAppear) withObject:nil afterDelay:0.0];
                                                          }];
    }
    
    if ([UIApplication sharedApplication].protectedDataAvailable) {
        [self performSelector:@selector(protectedViewDidAppear) withObject:nil afterDelay:0.0];
    }
    [super viewDidAppear:animated];
}

- (void)protectedViewDidAppear
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (self.protectedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.protectedObserver];
    self.protectedObserver = nil;
    
    if ([defs integerForKey:SETTINGS_MAX_DIGITS_KEY] == 5) {
        manager.dashFormat.currencySymbol = @"m" BTC NARROW_NBSP;
        manager.dashFormat.maximumFractionDigits = 5;
        manager.dashFormat.maximum = @((MAX_MONEY/DUFFS)*1000);
    }
    else if ([defs integerForKey:SETTINGS_MAX_DIGITS_KEY] == 8) {
        manager.dashFormat.currencySymbol = BTC NARROW_NBSP;
        manager.dashFormat.maximumFractionDigits = 8;
        manager.dashFormat.maximum = @(MAX_MONEY/DUFFS);
    }
    
    if (manager.noWallet && manager.noOldWallet) {
        if (! manager.passcodeEnabled) {
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:NSLocalizedString(@"turn device passcode on", nil)
                                         message:NSLocalizedString(@"\nA device passcode is needed to safeguard your wallet. Go to settings and "
                                                                   "turn passcode on to continue.", nil)
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* closeButton = [UIAlertAction
                                          actionWithTitle:NSLocalizedString(@"close app", nil)
                                          style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction * action) {
                                              exit(0);
                                          }];
            [alert addAction:closeButton];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else {
            [self.navigationController
             presentViewController:[self.storyboard instantiateViewControllerWithIdentifier:@"NewWalletNav"] animated:NO
             completion:^{
                 self.splash.hidden = YES;
                 self.navigationController.navigationBar.hidden = NO;
                 [self.pageViewController setViewControllers:@[self.receiveViewController]
                                                   direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
             }];
            
            manager.didAuthenticate = YES;
            self.showTips = YES;
            [self unlock:nil];
        }
    }
    else {
        [manager upgradeExtendedKeysWithCompletion:^(BOOL success, BOOL neededUpgrade, BOOL authenticated, BOOL cancelled) {
            if (!success && neededUpgrade && !authenticated) {
                UIAlertController * alert;
                if (cancelled) {
                    alert = [UIAlertController
                             alertControllerWithTitle:NSLocalizedString(@"failed wallet update", nil)
                             message:NSLocalizedString(@"you must enter your pin in order to enter dashwallet", nil)
                             preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* exitButton = [UIAlertAction
                                                 actionWithTitle:NSLocalizedString(@"exit", nil)
                                                 style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * action) {
                                                     exit(0);
                                                 }];
                    UIAlertAction* enterButton = [UIAlertAction
                                                  actionWithTitle:NSLocalizedString(@"enter", nil)
                                                  style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * action) {
                                                      [self protectedViewDidAppear];
                                                  }];
                    [alert addAction:exitButton];
                    [alert addAction:enterButton]; //ok button should be on the right side as per Apple guidelines, as reset is the less desireable option
                } else {
                    __block NSUInteger wait = [manager lockoutWaitTime];
                    NSString * waitTime = [NSString waitTimeFromNow:wait];
                    
                    alert = [UIAlertController
                             alertControllerWithTitle:NSLocalizedString(@"failed wallet update", nil)
                             message:[NSString stringWithFormat:NSLocalizedString(@"\ntry again in %@", nil),
                                      waitTime]
                             preferredStyle:UIAlertControllerStyleAlert];
                    NSTimer * timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer * _Nonnull timer) {
                        wait--;
                        alert.message = [NSString stringWithFormat:NSLocalizedString(@"\ntry again in %@", nil),
                                         [NSString waitTimeFromNow:wait]];
                        if (!wait) {
                            [timer invalidate];
                            [alert dismissViewControllerAnimated:TRUE completion:^{
                                [self protectedViewDidAppear];
                            }];
                        }
                    }];
                    UIAlertAction* resetButton = [UIAlertAction
                                                  actionWithTitle:NSLocalizedString(@"reset", nil)
                                                  style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction * action) {
                                                      [timer invalidate];
                                                      [manager showResetWalletWithCancelHandler:^{
                                                          [self protectedViewDidAppear];
                                                      }];
                                                  }];
                    UIAlertAction* exitButton = [UIAlertAction
                                                 actionWithTitle:NSLocalizedString(@"exit", nil)
                                                 style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * action) {
                                                     exit(0);
                                                 }];
                    [alert addAction:resetButton];
                    [alert addAction:exitButton]; //ok button should be on the right side as per Apple guidelines, as reset is the less desireable option
                }
                [self presentViewController:alert animated:YES completion:nil];
            }
            //if (!success) exit(0);
            if (_balance == UINT64_MAX && [defs objectForKey:BALANCE_KEY]) self.balance = [defs doubleForKey:BALANCE_KEY];
            self.splash.hidden = YES;
            
            self.navigationController.navigationBar.hidden = NO;
            self.pageViewController.view.alpha = 1.0;
            [self.receiveViewController updateAddress];
            if (self.reachability.currentReachabilityStatus == NotReachable) [self showErrorBar];
            
            if (self.navigationController.visibleViewController == self) {
                [self setNeedsStatusBarAppearanceUpdate];
            }
            
#if SNAPSHOT
            return;
#endif
            if (!authenticated) {
                if ([defs doubleForKey:PIN_UNLOCK_TIME_KEY] + WEEK_TIME_INTERVAL < [NSDate timeIntervalSinceReferenceDate]) {
                    [manager authenticateWithPrompt:nil andTouchId:NO alertIfLockout:YES completion:^(BOOL authenticated,BOOL cancelled) {
                        if (authenticated) {
                            [self unlock:nil];
                        }
                    }];
                }
            }
            
            if (self.navigationController.visibleViewController == self) {
                if (self.showTips) [self performSelector:@selector(tip:) withObject:nil afterDelay:0.3];
            }
            
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
                [[BRPeerManager sharedInstance] connect];
                [UIApplication sharedApplication].applicationIconBadgeNumber = 0; // reset app badge number
                
                if (self.url) {
                    [self.sendViewController handleURL:self.url];
                    self.url = nil;
                }
                else if (self.file) {
                    [self.sendViewController handleFile:self.file];
                    self.file = nil;
                }
            }
        }];
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (self.navBarTap) [self.navigationController.navigationBar removeGestureRecognizer:self.navBarTap];
    self.navBarTap = nil;
    [self hideTips];
    
    [super viewWillDisappear:animated];
}

- (BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender
{
    if ([self nextTip]) return NO;
    
    return YES;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    [super prepareForSegue:segue sender:sender];
    
    (segue.destinationViewController).transitioningDelegate = self;
    (segue.destinationViewController).modalPresentationStyle = UIModalPresentationCustom;
    [self hideErrorBarWithCompletion:nil];
    
    if ([sender isEqual:NSLocalizedString(@"show phrase", nil)]) { // show recovery phrase
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:NSLocalizedString(@"WARNING", nil)
                                     message:[NSString stringWithFormat:@"\n%@\n\n%@\n\n%@\n",
                                              [NSLocalizedString(@"\nDO NOT let anyone see your recovery\n"
                                                                 "phrase or they can spend your dash.\n", nil)
                                               stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]],
                                              [NSLocalizedString(@"\nNEVER type your recovery phrase into\n"
                                                                 "password managers or elsewhere.\n"
                                                                 "Other devices may be infected.\n", nil)
                                               stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]],
                                              [NSLocalizedString(@"\nDO NOT take a screenshot.\n"
                                                                 "Screenshots are visible to other apps\n"
                                                                 "and devices.\n", nil)
                                               stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]]
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* cancelButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"cancel", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                       }];
        UIAlertAction* showButton = [UIAlertAction
                                     actionWithTitle:NSLocalizedString(@"show", nil)
                                     style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction * action) {
                                         BRWalletManager *manager = [BRWalletManager sharedInstance];
                                         if (manager.noWallet) {
                                             BRSeedViewController *seedController = [self.storyboard instantiateViewControllerWithIdentifier:@"SeedViewController"];
                                             [self.navigationController pushViewController:seedController animated:YES];
                                         } else {
                                             [manager seedPhraseAfterAuthentication:^(NSString * _Nullable seedPhrase) {
                                                 if (seedPhrase.length > 0) {
                                                     BRSeedViewController *seedController = [self.storyboard instantiateViewControllerWithIdentifier:@"SeedViewController"];
                                                     seedController.seedPhrase = seedPhrase;
                                                     [self.navigationController pushViewController:seedController animated:YES];
                                                 }
                                             }];
                                         }
                                     }];
        [alert addAction:showButton];
        [alert addAction:cancelButton];
        [self presentViewController:alert animated:YES completion:nil];
    }
    //    else if ([sender isEqual:@"buy alert"]) {
    //        UINavigationController *nav = segue.destinationViewController;
    //
    //        [nav.topViewController performSelector:@selector(showBuy) withObject:nil afterDelay:1.0];
    //    }
}

- (void)viewDidLayoutSubviews
{
    [self scrollViewDidScroll:self.scrollView];
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self.reachability stopNotifier];
    if (self.navigationController.delegate == self) self.navigationController.delegate = nil;
    if (self.urlObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.urlObserver];
    if (self.fileObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.fileObserver];
    if (self.protectedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.protectedObserver];
    if (self.foregroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.foregroundObserver];
    if (self.backgroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.backgroundObserver];
    if (self.activeObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.activeObserver];
    if (self.resignActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.resignActiveObserver];
    if (self.reachabilityObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.reachabilityObserver];
    if (self.balanceObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.balanceObserver];
    if (self.seedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.seedObserver];
    if (self.syncStartedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncStartedObserver];
    if (self.syncFinishedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFinishedObserver];
    if (self.syncFailedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFailedObserver];
    AudioServicesDisposeSystemSoundID(self.pingsound);
}

- (void)setBalance:(uint64_t)balance
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (balance > _balance && [UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
        [self.view addSubview:[[[BRBubbleView viewWithText:[NSString
                                                            stringWithFormat:NSLocalizedString(@"received %@ (%@)", nil), [manager stringForDashAmount:balance - _balance],
                                                            [manager localCurrencyStringForDashAmount:balance - _balance]]
                                                    center:CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2)] popIn]
                               popOutAfterDelay:3.0]];
        [self ping];
    }
    
    _balance = balance;
    
    // use setDouble since setInteger won't hold a uint64_t
    [[NSUserDefaults standardUserDefaults] setDouble:balance forKey:BALANCE_KEY];
    
    if (self.shouldShowTips && self.navigationItem.titleView && [self.navigationItem.titleView isKindOfClass:[UILabel class]]) {
        [self updateTitleView];
    }
}

-(UILabel*)titleLabel {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    UILabel * titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 200)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [titleLabel setBackgroundColor:[UIColor clearColor]];
    NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor] useSignificantDigits:TRUE] mutableCopy];
    NSString * titleString = [NSString stringWithFormat:@" (%@)",
                              [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
    [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
    titleLabel.attributedText = attributedDashString;
    return titleLabel;
}

-(void)updateTitleView {
    if (self.navigationItem.titleView && [self.navigationItem.titleView isKindOfClass:[UILabel class]]) {
        BRWalletManager *manager = [BRWalletManager sharedInstance];
        NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor] useSignificantDigits:TRUE] mutableCopy];
        NSString * titleString = [NSString stringWithFormat:@" (%@)",
                                  [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
        [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
        ((UILabel*)self.navigationItem.titleView).attributedText = attributedDashString;
        [((UILabel*)self.navigationItem.titleView) sizeToFit];
    } else {
        self.navigationItem.titleView = [self titleLabel];
    }
}

- (void)showSyncing
{
    double progress = [BRPeerManager sharedInstance].syncProgress;
    
    if (progress > DBL_EPSILON && progress + DBL_EPSILON < 1.0 && [BRWalletManager sharedInstance].seedCreationTime + DAY_TIME_INTERVAL < [NSDate timeIntervalSinceReferenceDate]) {
        self.shouldShowTips = NO;
        self.navigationItem.titleView = nil;
        self.navigationItem.title = NSLocalizedString(@"Syncing:", nil);
    }
}

- (void)startActivityWithTimeout:(NSTimeInterval)timeout
{
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];
    
    if (timeout > 1 && start + timeout > self.start + self.timeout) {
        self.timeout = timeout;
        self.start = start;
    }
    
    if (timeout <= DBL_EPSILON) {
        if ([[BRPeerManager sharedInstance] timestampForBlockHeight:[BRPeerManager sharedInstance].lastBlockHeight] +
            WEEK_TIME_INTERVAL < [NSDate timeIntervalSinceReferenceDate]) {
            if ([BRWalletManager sharedInstance].seedCreationTime + DAY_TIME_INTERVAL < start) {
                self.shouldShowTips = NO;
                self.navigationItem.titleView = nil;
                self.navigationItem.title = NSLocalizedString(@"Syncing:", nil);
            }
        }
        else [self performSelector:@selector(showSyncing) withObject:nil afterDelay:5.0];
    }
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    self.progress.hidden = self.pulse.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ self.progress.alpha = 1.0; }];
    [self updateProgress];
}

- (void)stopActivityWithSuccess:(BOOL)success
{
    double progress = [BRPeerManager sharedInstance].syncProgress;
    
    self.start = self.timeout = 0.0;
    if (progress > DBL_EPSILON && progress + DBL_EPSILON < 1.0) return; // not done syncing
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    if (self.progress.alpha < 0.5) return;
    
    if (success) {
        [self.progress setProgress:1.0 animated:YES];
        [self.pulse setProgress:1.0 animated:YES];
        
        [UIView animateWithDuration:0.2 animations:^{
            self.progress.alpha = self.pulse.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.progress.hidden = self.pulse.hidden = YES;
            self.progress.progress = self.pulse.progress = 0.0;
        }];
    }
    else {
        self.progress.hidden = self.pulse.hidden = YES;
        self.progress.progress = self.pulse.progress = 0.0;
    }
    [self updateTitleView];
}

- (void)setProgressTo:(NSNumber *)n
{
    self.progress.progress = n.floatValue;
}

- (void)updateProgress
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateProgress) object:nil];
    
    static int counter = 0;
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.start;
    double progress = [BRPeerManager sharedInstance].syncProgress;
    
    if (progress > DBL_EPSILON && ! self.shouldShowTips && self.tipView.alpha > 0.5) {
        self.tipView.text = [NSString stringWithFormat:NSLocalizedString(@"block #%d of %d", nil),
                             [BRPeerManager sharedInstance].lastBlockHeight,
                             [BRPeerManager sharedInstance].estimatedBlockHeight];
    }
    
    if (self.timeout > 1.0 && 0.1 + 0.9*elapsed/self.timeout < progress) progress = 0.1 + 0.9*elapsed/self.timeout;
    
    if ((counter % 13) == 0) {
        self.pulse.alpha = 1.0;
        [self.pulse setProgress:progress animated:progress > self.pulse.progress];
        [self.progress setProgress:progress animated:progress > self.progress.progress];
        
        if (progress > self.progress.progress) {
            [self performSelector:@selector(setProgressTo:) withObject:@(progress) afterDelay:1.0];
        }
        else self.progress.progress = progress;
        
        [UIView animateWithDuration:1.59 delay:1.0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            self.pulse.alpha = 0.0;
        } completion:nil];
        
        [self.pulse performSelector:@selector(setProgress:) withObject:nil afterDelay:2.59];
    }
    else if ((counter % 13) >= 5) {
        [self.progress setProgress:progress animated:progress > self.progress.progress];
        [self.pulse setProgress:progress animated:progress > self.pulse.progress];
    }
    
    counter++;
    self.navigationItem.title = [NSString stringWithFormat:@"%@ %0.1f%%",NSLocalizedString(@"Syncing:", nil), (progress > 0.1 ? progress - 0.1 : 0.0)*111.0];
    if (progress + DBL_EPSILON >= 1.0) {
        if (self.timeout < 1.0) [self stopActivityWithSuccess:YES];
        if (! self.shouldShowTips) [self hideTips];
        self.shouldShowTips = YES;
        if (! [BRWalletManager sharedInstance].didAuthenticate) self.navigationItem.titleView = self.logo;
    }
    else [self performSelector:@selector(updateProgress) withObject:nil afterDelay:0.2];
}

- (void)ping
{
    AudioServicesPlaySystemSound(self.pingsound);
}

- (void)showErrorBar
{
    if (self.navigationItem.prompt != nil || self.navigationController.presentedViewController != nil) return;
    self.navigationItem.prompt = @"";
    self.errorBar.hidden = NO;
    self.errorBar.alpha = 0.0;
    
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration delay:0.0
                        options:UIViewAnimationOptionCurveEaseIn animations:^{
                            self.burger.center = CGPointMake(self.burger.center.x, 70.0);
                            self.errorBar.alpha = 1.0;
                        } completion:nil];
    
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (! self.shouldShowTips) [self hideTips];
    self.shouldShowTips = YES;
    if (! manager.didAuthenticate) self.navigationItem.titleView = self.logo;
    self.balance = _balance; // reset navbar title
    self.progress.hidden = self.pulse.hidden = YES;
}

- (void)hideErrorBarWithCompletion:(void (^ _Nullable)(BOOL finished))completion
{
    if (self.navigationItem.prompt == nil) return;
    [UIView animateWithDuration:UINavigationControllerHideShowBarDuration delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
                            self.burger.center = CGPointMake(self.burger.center.x, 40.0);
                            self.errorBar.alpha = 0.0;
                        } completion:^(BOOL finished) {
                            self.navigationItem.prompt = nil;
                            self.errorBar.hidden = YES;
                            if (completion) completion(finished);
                        }];
}

- (void)showBackupDialogIfNeeded
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (self.navigationController.visibleViewController != self || ! [defs boolForKey:WALLET_NEEDS_BACKUP_KEY] ||
        manager.wallet.balance == 0 || [defs doubleForKey:BACKUP_DIALOG_TIME_KEY] > now - 36*60*60) return;
    
    BOOL first = ([defs doubleForKey:BACKUP_DIALOG_TIME_KEY] < 1.0) ? YES : NO;
    
    [defs setDouble:now forKey:BACKUP_DIALOG_TIME_KEY];
    UIAlertController * alert = [UIAlertController
                                 alertControllerWithTitle:(first) ? NSLocalizedString(@"you received dash!", nil) : NSLocalizedString(@"IMPORTANT", nil)
                                 message:[NSString stringWithFormat:NSLocalizedString(@"\n%@\n\nif you ever lose your phone, you will need it to "
                                                                                      "recover your wallet", nil),
                                          (first) ? NSLocalizedString(@"next, write down your recovery phrase", nil) :
                                          NSLocalizedString(@"WRITE DOWN YOUR RECOVERY PHRASE", nil)]
                                 preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* doItLaterButton = [UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"do it later", nil)
                                      style:UIAlertActionStyleCancel
                                      handler:^(UIAlertAction * action) {
                                          
                                      }];
    UIAlertAction* showPhraseButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"show phrase", nil)
                                       style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction * action) {
                                           [self performSegueWithIdentifier:@"SettingsSegue" sender:self];
                                       }];
    
    [alert addAction:doItLaterButton];
    [alert addAction:showPhraseButton];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)hideTips
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(tip:) object:nil];
    if (self.tipView.alpha > 0.5) [self.tipView popOut];
}

- (BOOL)nextTip
{
    if (self.tipView.alpha < 0.5) { // if the tip view is dismissed, cycle through child view controller tips
        BOOL ret;
        
        if (self.inNextTip) return NO; // break out of recursive loop
        self.inNextTip = YES;
        ret = [self.pageViewController.viewControllers.lastObject nextTip];
        self.inNextTip = NO;
        return ret;
    }
    
    BRBubbleView *tipView = self.tipView;
    
    self.tipView = nil;
    [tipView popOut];
    
    if ([tipView.text hasPrefix:BALANCE_TIP]) {
        BRWalletManager *m = [BRWalletManager sharedInstance];
        UINavigationBar *b = self.navigationController.navigationBar;
        NSString *text = [NSString stringWithFormat:MDASH_TIP, m.dashFormat.currencySymbol, [m stringForDashAmount:DUFFS]];
        CGRect r = [self.navigationItem.title boundingRectWithSize:b.bounds.size options:0
                                                        attributes:b.titleTextAttributes context:nil];
        
        self.tipView = [BRBubbleView viewWithAttributedText:[text attributedStringForDashSymbolWithTintColor:[UIColor whiteColor] dashSymbolSize:CGSizeMake(13, 11)]
                                                   tipPoint:CGPointMake(b.center.x + 5.0 - r.size.width/2.0,
                                                                        b.frame.origin.y + b.frame.size.height - 10)
                                               tipDirection:BRBubbleTipDirectionUp];
        self.tipView.backgroundColor = tipView.backgroundColor;
        self.tipView.font = tipView.font;
        self.tipView.userInteractionEnabled = NO;
        [self.view addSubview:[self.tipView popIn]];
    }
    else if (self.showTips) {
        self.showTips = NO;
        [self.pageViewController.viewControllers.lastObject tip:self];
    }
    
    return YES;
}

// MARK: - IBAction

- (IBAction)tip:(id)sender
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (sender == self.receiveViewController) {
        BRSendViewController *sendController = self.sendViewController;
        
        [(id)self.pageViewController setViewControllers:@[sendController]
                                              direction:UIPageViewControllerNavigationDirectionReverse animated:YES
                                             completion:^(BOOL finished) { [sendController tip:sender]; }];
    }
    else if (sender == self.sendViewController) {
        self.scrollView.scrollEnabled = YES;
        [(id)self.pageViewController setViewControllers:@[self.receiveViewController]
                                              direction:UIPageViewControllerNavigationDirectionForward animated:YES completion:nil];
    }
    else if (self.showTips && manager.seedCreationTime + DAY_TIME_INTERVAL < [NSDate timeIntervalSinceReferenceDate]) {
        self.showTips = NO;
    }
    else {
        UINavigationBar *b = self.navigationController.navigationBar;
        NSString *tip;
        if (manager.bitcoinDashPrice) {
            tip = (self.shouldShowTips) ? [NSString stringWithFormat:@"%@ \n 1%@ = %.4f%@ (%@)",BALANCE_TIP_START,DASH,manager.bitcoinDashPrice.doubleValue,BTC,[manager localCurrencyStringForDashAmount:DUFFS]] :
            [NSString stringWithFormat:NSLocalizedString(@"block #%d of %d", nil),
             [[BRPeerManager sharedInstance] lastBlockHeight],
             [[BRPeerManager sharedInstance] estimatedBlockHeight]];
        } else {
            tip = (self.shouldShowTips) ? [NSString stringWithFormat:@"%@",BALANCE_TIP]:
            [NSString stringWithFormat:NSLocalizedString(@"block #%d of %d", nil),
             [[BRPeerManager sharedInstance] lastBlockHeight],
             [[BRPeerManager sharedInstance] estimatedBlockHeight]];
        }
        NSMutableAttributedString *attributedTip = [[NSMutableAttributedString alloc]
                                                    initWithString:[tip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        
        NSRange range = [attributedTip.string rangeOfString:DASH options:NSBackwardsSearch];
        if (range.length != 0)
            [attributedTip replaceCharactersInRange:range
                               withAttributedString:[NSString dashSymbolAttributedStringWithTintColor:[UIColor whiteColor] forDashSymbolSize:CGSizeMake(13, 11)]];
        self.tipView = [BRBubbleView viewWithAttributedText:attributedTip
                                                   tipPoint:CGPointMake(b.center.x, b.frame.origin.y + b.frame.size.height - 10)
                                               tipDirection:BRBubbleTipDirectionUp];
        self.tipView.font = [UIFont systemFontOfSize:15.0];
        self.tipView.userInteractionEnabled = NO;
        UIWindow *currentWindow = [UIApplication sharedApplication].keyWindow;
        [currentWindow addSubview:[self.tipView popIn]];
        if (self.showTips) self.scrollView.scrollEnabled = NO;
    }
}

- (IBAction)unlock:(id)sender
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    if (manager.didAuthenticate) {
        [self updateTitleView];
        [self.navigationItem setRightBarButtonItem:nil animated:(sender) ? YES : NO];
    } else {
        [BREventManager saveEvent:@"root:unlock"];
        [manager authenticateWithPrompt:nil andTouchId:YES alertIfLockout:YES completion:^(BOOL authenticated,BOOL cancelled) {
            if (authenticated) {
                [BREventManager saveEvent:@"root:unlock_success"];
                [self updateTitleView];
                [self.navigationItem setRightBarButtonItem:nil animated:(sender) ? YES : NO];
            }
        }];
    }
}

- (IBAction)connect:(id)sender
{
    [BREventManager saveEvent:@"root:connect"];
    if (! sender && [self.reachability currentReachabilityStatus] == NotReachable) return;
    
    [[BRPeerManager sharedInstance] connect];
    [BREventManager saveEvent:@"root:connect_success"];
    if (self.reachability.currentReachabilityStatus == NotReachable) [self showErrorBar];
}

- (IBAction)navBarTap:(id)sender
{
    if ([self nextTip]) return;
    
    if (! self.errorBar.hidden) {
        [self hideErrorBarWithCompletion:^(BOOL finished) {
            [self connect:sender];
        }];
    }
    else if (! [BRWalletManager sharedInstance].didAuthenticate && self.shouldShowTips) {
        [self unlock:sender];
    }
    else [self tip:sender];
}

- (void)showBuyAlert
{
    // grab a blurred image for the background
    UIGraphicsBeginImageContext(self.navigationController.view.bounds.size);
    [self.navigationController.view drawViewHierarchyInRect:self.navigationController.view.bounds
                                         afterScreenUpdates:NO];
    UIImage *bgImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIImage *blurredBgImg = [bgImg blurWithRadius:3];
    
    // display the popup
    __weak BREventConfirmView *view =
    [[NSBundle mainBundle] loadNibNamed:@"BREventConfirmView" owner:nil options:nil][0];
    view.titleLabel.text = NSLocalizedString(@"Buy dash in dashwallet!", nil);
    view.descriptionLabel.text =
    NSLocalizedString(@"You can now buy dash in\ndashwallet with cash or\nbank transfer.", nil);
    [view.okBtn setTitle:NSLocalizedString(@"Try It!", nil) forState:UIControlStateNormal];
    
    view.image = blurredBgImg;
    view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    view.frame = self.navigationController.view.bounds;
    view.alpha = 0;
    [self.navigationController.view addSubview:view];
    
    [UIView animateWithDuration:.5 animations:^{
        view.alpha = 1;
    }];
    
    view.completionHandler = ^(BOOL didApprove) {
        if (didApprove) [self performSegueWithIdentifier:@"SettingsSegue" sender:@"buy alert"];
        
        [UIView animateWithDuration:.5 animations:^{
            view.alpha = 0;
        } completion:^(BOOL finished) {
            [view removeFromSuperview];
        }];
    };
}

#if SNAPSHOT
- (IBAction)nextScreen:(id)sender
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
    if (self.navigationController.presentedViewController) {
        if (manager.noWallet) [manager generateRandomSeed];
        self.showTips = NO;
        [self.navigationController dismissViewControllerAnimated:NO completion:^{
            manager.didAuthenticate = NO;
            self.navigationItem.titleView = self.logo;
            self.navigationItem.rightBarButtonItem = self.lock;
            self.pageViewController.view.alpha = 1.0;
            self.navigationController.navigationBar.hidden = YES;
            [[UIApplication sharedApplication] setStatusBarHidden:YES];
            self.splash.hidden = NO;
            [self.splash
             addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nextScreen:)]];
        }];
    }
    else if (! self.splash.hidden) {
        self.navigationController.navigationBar.hidden = NO;
        [[UIApplication sharedApplication] setStatusBarHidden:NO];
        self.splash.hidden = YES;
        [self stopActivityWithSuccess:YES];
        [self.pageViewController setViewControllers:@[self.receiveViewController]
                                          direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];
        self.receiveViewController.paymentRequest =
        [BRPaymentRequest requestWithString:@"n2eMqTT929pb1RDNuqEnxdaLau1rxy3efi"];
        [self.receiveViewController updateAddress];
        [self.progress removeFromSuperview];
        [self.pulse removeFromSuperview];
    }
}
#endif

// MARK: - UIPageViewControllerDataSource

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController
      viewControllerBeforeViewController:(UIViewController *)viewController
{
    return (viewController == self.receiveViewController) ? self.sendViewController : nil;
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController
       viewControllerAfterViewController:(UIViewController *)viewController
{
    return (viewController == self.sendViewController) ? self.receiveViewController : nil;
}

- (NSInteger)presentationCountForPageViewController:(UIPageViewController *)pageViewController
{
    return 2;
}

- (NSInteger)presentationIndexForPageViewController:(UIPageViewController *)pageViewController
{
    return (pageViewController.viewControllers.lastObject == self.receiveViewController) ? 1 : 0;
}

// MARK: - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGFloat off = scrollView.contentOffset.x + (scrollView.contentInset.left < 0 ? scrollView.contentInset.left : 0);
    
    self.wallpaperXLeft.constant = -PARALAX_RATIO*off;
}

// MARK: - UIViewControllerAnimatedTransitioning

// This is used for percent driven interactive transitions, as well as for container controllers that have companion
// animations that might need to synchronize with the main animation.
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext
{
    return (transitionContext.isAnimated) ? 0.35 : 0.0;
}

// This method can only be a nop if the transition is interactive and not a percentDriven interactive transition.
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    UIView *containerView = transitionContext.containerView;
    UIViewController *to = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey],
    *from = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    
    if (to == self || from == self) { // nav stack push/pop
        self.progress.hidden = self.pulse.hidden = YES;
        [containerView addSubview:to.view];
        to.view.center = CGPointMake(containerView.frame.size.width*(to == self ? -1 : 3)/2, to.view.center.y);
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                  to.view.center = from.view.center;
                  from.view.center = CGPointMake(containerView.frame.size.width*(to == self ? 3 : -1)/2, from.view.center.y);
                  self.wallpaperXLeft.constant = containerView.frame.size.width*(to == self ? 0 : -1)*PARALAX_RATIO;
              } completion:^(BOOL finished) {
                  if (to == self) {
                      [from.view removeFromSuperview];
                      self.navigationController.navigationBarHidden = YES; // hack to fix topLayoutGuide bug
                      [self.navigationController performSelector:@selector(setNavigationBarHidden:) withObject:nil
                                                      afterDelay:0];
                  }
                  
                  if (self.progress.progress > 0) self.progress.hidden = self.pulse.hidden = NO;
                  [transitionContext completeTransition:YES];
              }];
    }
    else if ([to isKindOfClass:[UINavigationController class]] && from == self.navigationController) { // modal display
        // to.view must be added to superview prior to positioning it off screen for its navbar to underlap statusbar
        [self.navigationController.navigationBar.superview insertSubview:to.view
                                                            belowSubview:self.navigationController.navigationBar];
        [containerView layoutIfNeeded];
        to.view.center = CGPointMake(to.view.center.x, containerView.frame.size.height*3/2);
        
        UINavigationItem *item = [(id)to topViewController].navigationItem;
        UIView *titleView = item.titleView;
        UIBarButtonItem *rightButton = item.rightBarButtonItem;
        
        item.title = nil;
        item.leftBarButtonItem.image = [UIImage imageNamed:@"none"];
        item.titleView = nil;
        item.rightBarButtonItem = nil;
        self.navigationItem.leftBarButtonItem.image = [UIImage imageNamed:@"none"];
        [containerView addSubview:self.burger];
        [containerView layoutIfNeeded];
        
        self.burger.center = CGPointMake(26.0, self.topLayoutGuide.length - 24);
        self.burger.hidden = NO;
        [self.burger setX:YES completion:nil];
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                  to.view.center = CGPointMake(to.view.center.x, containerView.frame.size.height/2);
                  self.pageViewController.view.alpha = 0.0;
                  self.pageViewController.view.center = CGPointMake(self.pageViewController.view.center.x,
                                                                    containerView.frame.size.height/4.0);
              } completion:^(BOOL finished) {
                  self.pageViewController.view.center = CGPointMake(self.pageViewController.view.center.x,
                                                                    containerView.frame.size.height/2.0);
                  
                  if (! manager.didAuthenticate) {
                      item.rightBarButtonItem = rightButton;
                      if (self.shouldShowTips) item.titleView = titleView;
                  } else {
                      if ([[(id)to topViewController] respondsToSelector:@selector(updateTitleView)]) {
                          [[(id)to topViewController] performSelector:@selector(updateTitleView)];
                      } else {
                          item.title = self.navigationItem.title;
                      }
                  }
                  item.leftBarButtonItem.image = [UIImage imageNamed:@"x"];
                  [containerView addSubview:to.view];
                  [transitionContext completeTransition:YES];
              }];
    }
    else if ([from isKindOfClass:[UINavigationController class]] && to == self.navigationController) { // modal dismiss
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground) {
            [[BRPeerManager sharedInstance] connect];
            [self.sendViewController updateClipboardText];
        }
        
        if (manager.didAuthenticate) [self unlock:nil];
        [self.navigationController.navigationBar.superview insertSubview:from.view
                                                            belowSubview:self.navigationController.navigationBar];
        
        UINavigationItem *item = [(id)from topViewController].navigationItem;
        UIView *titleView = item.titleView;
        UIBarButtonItem *rightButton = item.rightBarButtonItem;
        
        item.title = nil;
        item.leftBarButtonItem.image = [UIImage imageNamed:@"none"];
        item.titleView = nil;
        item.rightBarButtonItem = nil;
        self.navigationItem.leftBarButtonItem.image = [UIImage imageNamed:@"none"];
        self.burger.hidden = NO;
        [containerView layoutIfNeeded];
        self.burger.center = CGPointMake(26.0, self.topLayoutGuide.length - 24);
        [self.burger setX:NO completion:nil];
        self.pageViewController.view.alpha = 0.0;
        self.pageViewController.view.center = CGPointMake(self.pageViewController.view.center.x,
                                                          containerView.frame.size.height/4.0);
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                  from.view.center = CGPointMake(from.view.center.x, containerView.frame.size.height*3/2);
                  self.pageViewController.view.alpha = 1.0;
                  self.pageViewController.view.center = CGPointMake(self.pageViewController.view.center.x,
                                                                    containerView.frame.size.height/2);
              } completion:^(BOOL finished) {
                  item.rightBarButtonItem = rightButton;
                  item.titleView = titleView;
                  item.title = self.navigationItem.title;
                  item.leftBarButtonItem.image = [UIImage imageNamed:@"x"];
                  [from.view removeFromSuperview];
                  self.burger.hidden = YES;
                  self.navigationItem.leftBarButtonItem.image = [UIImage imageNamed:@"burger"];
                  [transitionContext completeTransition:YES];
                  if (self.reachability.currentReachabilityStatus == NotReachable) [self showErrorBar];
              }];
    }
}

// MARK: - UINavigationControllerDelegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
                                  animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)fromVC
                                                 toViewController:(UIViewController *)toVC
{
    return self;
}

// MARK: - UIViewControllerTransitioningDelegate

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
                                                                  presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source
{
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed
{
    return self;
}

// MARK: - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch{
    
    if (gestureRecognizer == self.navBarTap && [touch.view isKindOfClass:[UIControl class]]) {
        return NO;
    }
    return YES;
}

@end
