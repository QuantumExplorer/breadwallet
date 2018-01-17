//
//  BRRestoreViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 6/13/13.
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

#import "BRRestoreViewController.h"
#import "BRWalletManager.h"
#import "BRMnemonic.h"
#import "BRAddressEntity.h"
#import "NSMutableData+Bitcoin.h"
#import "NSString+Bitcoin.h"
#import "NSManagedObject+Sugar.h"
#import "BREventManager.h"
#import "BRPeerManager.h"

#define PHRASE_LENGTH 12


@interface BRRestoreViewController ()

@property (nonatomic, strong) IBOutlet UITextView *textView;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *textViewYBottom;
@property (nonatomic, strong) id keyboardObserver, resignActiveObserver;

@end


@implementation BRRestoreViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    // TODO: create secure versions of keyboard and UILabel and use in place of UITextView
    // TODO: autocomplete based on 4 letter prefixes of mnemonic words
    
    self.textView.layer.cornerRadius = 5.0;
    
    self.keyboardObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            [UIView animateWithDuration:[note.userInfo[UIKeyboardAnimationDurationUserInfoKey] floatValue] delay:0.0
             options:[note.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue] animations:^{
                 self.textViewYBottom.constant =
                     [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height + 12.0;
                 [self.view layoutIfNeeded];
             } completion:nil];
        }];
    
    self.resignActiveObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.textView.text = nil;
        }];
    
    self.textView.layer.borderColor = [UIColor colorWithWhite:0.0 alpha:0.25].CGColor;
    self.textView.layer.borderWidth = 0.5;
    UILabel * titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 100)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [titleLabel setBackgroundColor:[UIColor clearColor]];
    [titleLabel setText:(self.navigationController.viewControllers.firstObject != self)?NSLocalizedString(@"recovery phrase",@"recovery phrase"):NSLocalizedString(@"confirm",@"confirm")];
    [titleLabel setTextColor:[UIColor blackColor]];
    self.navigationItem.titleView = titleLabel;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self.textView becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated
{
    self.textView.text = nil;
    
    [super viewWillDisappear:animated];
}

- (void)dealloc
{
    if (self.keyboardObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.keyboardObserver];
    if (self.resignActiveObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.resignActiveObserver];
}

- (void)wipeWithPhrase:(NSString *)phrase
{
    [BREventManager saveEvent:@"restore:wipe"];
    
    @autoreleasepool {
        BRWalletManager *manager = [BRWalletManager sharedInstance];
        BRPeerManager *peerManager = [BRPeerManager sharedInstance];
        if ([phrase isEqual:@"wipe"]) {
            if ((manager.wallet.balance == 0) && ([peerManager timestampForBlockHeight:peerManager.lastBlockHeight] + 60 * 2.5 * 5 > [NSDate timeIntervalSinceReferenceDate])) {
                [BREventManager saveEvent:@"restore:wipe_empty_wallet"];
                UIAlertController * actionSheet = [UIAlertController
                                             alertControllerWithTitle:nil
                                             message:nil
                                             preferredStyle:UIAlertControllerStyleActionSheet];
                UIAlertAction* cancelButton = [UIAlertAction
                                             actionWithTitle:NSLocalizedString(@"cancel", nil)
                                             style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction * action) {
                                                 [self.textView becomeFirstResponder];
                                             }];
                UIAlertAction* wipeButton = [UIAlertAction
                                              actionWithTitle:NSLocalizedString(@"wipe", nil)
                                              style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction * action) {
                                                  [self wipeWallet];
                                              }];
                [actionSheet addAction:cancelButton];
                [actionSheet addAction:wipeButton];
                [self presentViewController:actionSheet animated:YES completion:nil];
            } else {
                UIAlertController * actionSheet = [UIAlertController
                                                   alertControllerWithTitle:NSLocalizedString(@"This wallet is not empty or sync has not finished, you may not wipe it without the recovery phrase", nil)
                                                   message:NSLocalizedString(@"If you still would like to wipe it please input : \"I accept that I will lose my coins if I no longer possess the recovery phrase\"", nil)
                                                   preferredStyle:UIAlertControllerStyleAlert];
                UIAlertAction* okButton = [UIAlertAction
                                             actionWithTitle:NSLocalizedString(@"ok", nil)
                                             style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction * action) {
                                                 
                                             }];
                [actionSheet addAction:okButton];
                [self presentViewController:actionSheet animated:YES completion:nil];
            }
        } else if ([[phrase lowercaseString] isEqualToString:@"i accept that i will lose my coins if i no longer possess the recovery phrase"]) {
                [BREventManager saveEvent:@"restore:wipe_full_wallet"];
            UIAlertController * actionSheet = [UIAlertController
                                               alertControllerWithTitle:nil
                                               message:nil
                                               preferredStyle:UIAlertControllerStyleActionSheet];
            UIAlertAction* cancelButton = [UIAlertAction
                                           actionWithTitle:NSLocalizedString(@"cancel", nil)
                                           style:UIAlertActionStyleCancel
                                           handler:^(UIAlertAction * action) {
                                               [self.textView becomeFirstResponder];
                                           }];
            UIAlertAction* wipeButton = [UIAlertAction
                                         actionWithTitle:NSLocalizedString(@"wipe", nil)
                                         style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction * action) {
                                             [self wipeWallet];
                                         }];
            [actionSheet addAction:cancelButton];
            [actionSheet addAction:wipeButton];
            [self presentViewController:actionSheet animated:YES completion:nil];
            return;
        } else {
            [manager seedPhraseAfterAuthentication:^(NSString * _Nullable seedPhrase) {
                if ([[manager.sequence extendedPublicKeyForAccount:0 fromSeed:[manager.mnemonic deriveKeyFromPhrase:seedPhrase withPassphrase:nil] purpose:44]
                     isEqual:manager.extendedBIP44PublicKey] || [[manager.sequence extendedPublicKeyForAccount:0 fromSeed:[manager.mnemonic deriveKeyFromPhrase:phrase withPassphrase:nil] purpose:0]
                                                                 isEqual:manager.extendedBIP44PublicKey] || [seedPhrase isEqual:@"wipe"]) { //@"wipe" comes from too many bad auth attempts
                    [BREventManager saveEvent:@"restore:wipe_good_recovery_phrase"];
                    UIAlertController * actionSheet = [UIAlertController
                                                       alertControllerWithTitle:nil
                                                       message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
                    UIAlertAction* cancelButton = [UIAlertAction
                                                   actionWithTitle:NSLocalizedString(@"cancel", nil)
                                                   style:UIAlertActionStyleCancel
                                                   handler:^(UIAlertAction * action) {
                                                       [self.textView becomeFirstResponder];
                                                   }];
                    UIAlertAction* wipeButton = [UIAlertAction
                                                 actionWithTitle:NSLocalizedString(@"wipe", nil)
                                                 style:UIAlertActionStyleDestructive
                                                 handler:^(UIAlertAction * action) {
                                                     [self wipeWallet];
                                                 }];
                    [actionSheet addAction:cancelButton];
                    [actionSheet addAction:wipeButton];
                    [self presentViewController:actionSheet animated:YES completion:nil];
                }
                else if (seedPhrase) {
                    [BREventManager saveEvent:@"restore:wipe_bad_recovery_phrase"];
                    UIAlertController * alert = [UIAlertController
                                                 alertControllerWithTitle:@""
                                                 message:NSLocalizedString(@"recovery phrase doesn't match", nil)
                                                 preferredStyle:UIAlertControllerStyleAlert];
                    UIAlertAction* okButton = [UIAlertAction
                                               actionWithTitle:NSLocalizedString(@"ok", nil)
                                               style:UIAlertActionStyleCancel
                                               handler:^(UIAlertAction * action) {
                                                   [self.textView becomeFirstResponder];
                                               }];
                    [alert addAction:okButton];
                    [self presentViewController:alert animated:YES completion:nil];
                }
                else [self.textView becomeFirstResponder];
            }];
        }
    }
}

- (void)wipeWallet
{
    
    [[BRWalletManager sharedInstance] setSeedPhrase:nil];
    self.textView.text = nil;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:WALLET_NEEDS_BACKUP_KEY];
    
    UIViewController *p = self.navigationController.presentingViewController.presentingViewController;
    
    if (! p) {
        UIAlertController * alert = [UIAlertController
                                     alertControllerWithTitle:@""
                                     message:NSLocalizedString(@"the app will now close", nil)
                                     preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* closeButton = [UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"close app", nil)
                                      style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction * action) {
                                          exit(0);
                                      }];
        [alert addAction:closeButton];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    [p dismissViewControllerAnimated:NO completion:^{
        [p presentViewController:[self.storyboard instantiateViewControllerWithIdentifier:@"NewWalletNav"] animated:NO
                      completion:nil];
    }];
}

// MARK: - IBAction

- (IBAction)cancel:(id)sender
{
    [BREventManager saveEvent:@"restore:cancel"];
    
    if (self.navigationController.presentingViewController) {
        [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
    else [self.navigationController popViewControllerAnimated:NO];
}

// MARK: - UITextViewDelegate

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text
{
    static NSCharacterSet *invalid = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet letterCharacterSet];

        [set formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        invalid = set.invertedSet;
    });

    if (! [text isEqual:@"\n"]) return YES; // not done entering phrase
    
    @autoreleasepool {  // @autoreleasepool ensures sensitive data will be deallocated immediately
        BRWalletManager *manager = [BRWalletManager sharedInstance];
        NSString *phrase = [manager.mnemonic cleanupPhrase:textView.text], *incorrect = nil;
        BOOL isLocal = YES, noWallet = manager.noWallet;
        
        if (! [textView.text hasPrefix:@"watch"] && ! [phrase isEqual:textView.text]) textView.text = phrase;
        phrase = [manager.mnemonic normalizePhrase:phrase];
        
        NSArray *a = CFBridgingRelease(CFStringCreateArrayBySeparatingStrings(SecureAllocator(), (CFStringRef)phrase,
                                                                              CFSTR(" ")));

        for (NSString *word in a) {
            if (! [manager.mnemonic wordIsLocal:word]) isLocal = NO;
            if ([manager.mnemonic wordIsValid:word]) continue;
            incorrect = word;
            break;
        }

        if ([phrase isEqualToString:@"wipe"] || [[phrase lowercaseString] isEqualToString:@"i accept that i will lose my coins if i no longer possess the recovery phrase"]) { // shortcut word to force the wipe option to appear
            [self.textView resignFirstResponder];
            [self performSelector:@selector(wipeWithPhrase:) withObject:phrase afterDelay:0.0];
        }
        else if (incorrect && noWallet && [textView.text hasPrefix:@"watch"]) { // address list watch only wallet
            manager.seedPhrase = @"wipe";

            [[NSManagedObject context] performBlockAndWait:^{
                int32_t n = 0;
                
                for (NSString *s in [textView.text componentsSeparatedByCharactersInSet:[NSCharacterSet
                                     alphanumericCharacterSet].invertedSet]) {
                    if (! [s isValidBitcoinAddress]) continue;
                    
                    BRAddressEntity *e = [BRAddressEntity managedObject];
                    
                    e.address = s;
                    e.index = n++;
                    e.internal = NO;
                }
            }];
            
            [NSManagedObject saveContext];
            textView.text = nil;
            [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
        else if (incorrect) {
            [BREventManager saveEvent:@"restore:invalid_word"];
            textView.selectedRange = [textView.text.lowercaseString rangeOfString:incorrect];
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:@""
                                         message:[NSString stringWithFormat:NSLocalizedString(@"\"%@\" is not a recovery phrase word", nil),
                                                  incorrect]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                                                     actionWithTitle:NSLocalizedString(@"ok", nil)
                                                                     style:UIAlertActionStyleCancel
                                                                     handler:^(UIAlertAction * action) {
                                                                         //Handle your yes please button action here
                                                                     }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else if (a.count != PHRASE_LENGTH) {
            [BREventManager saveEvent:@"restore:invalid_num_words"];
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:@""
                                         message:[NSString stringWithFormat:NSLocalizedString(@"recovery phrase must have %d words", nil),
                                                  PHRASE_LENGTH]
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           //Handle your yes please button action here
                                       }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else if (isLocal && ! [manager.mnemonic phraseIsValid:phrase]) {
            [BREventManager saveEvent:@"restore:bad_phrase"];
            UIAlertController * alert = [UIAlertController
                                         alertControllerWithTitle:@""
                                         message:NSLocalizedString(@"bad recovery phrase", nil)
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction* okButton = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"ok", nil)
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction * action) {
                                           //Handle your yes please button action here
                                       }];
            [alert addAction:okButton];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else if (! noWallet) {
            [self.textView resignFirstResponder];
            [self performSelector:@selector(wipeWithPhrase:) withObject:phrase afterDelay:0.0];
        }
        else {
            //TODO: offer the user an option to move funds to a new seed if their wallet device was lost or stolen
            manager.seedPhrase = phrase;
            textView.text = nil;
            [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
    }
    
    return NO;
}

@end
