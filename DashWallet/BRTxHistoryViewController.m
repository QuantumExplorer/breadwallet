//
//  BRTxHistoryViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 6/11/13.
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

#import "BRTxHistoryViewController.h"
#import "BRRootViewController.h"
#import "BRSettingsViewController.h"
#import "BRTxDetailViewController.h"
#import "BRSeedViewController.h"
#import "BRWalletManager.h"
#import "BRPeerManager.h"
#import "BRTransaction.h"
#import "NSString+Bitcoin.h"
#import "NSData+Bitcoin.h"
#import "UIImage+Utils.h"
#import "BREventConfirmView.h"
#import "BREventManager.h"
#import "NSString+Dash.h"
#import <WebKit/WebKit.h>

#define TRANSACTION_CELL_HEIGHT 75

static NSString *dateFormat(NSString *template)
{
    NSString *format = [NSDateFormatter dateFormatFromTemplate:template options:0 locale:[NSLocale currentLocale]];
    
    format = [format stringByReplacingOccurrencesOfString:@", " withString:@" "];
    format = [format stringByReplacingOccurrencesOfString:@" a" withString:@"a"];
    format = [format stringByReplacingOccurrencesOfString:@"hh" withString:@"h"];
    format = [format stringByReplacingOccurrencesOfString:@" ha" withString:@"@ha"];
    format = [format stringByReplacingOccurrencesOfString:@"HH" withString:@"H"];
    format = [format stringByReplacingOccurrencesOfString:@"H '" withString:@"H'"];
    format = [format stringByReplacingOccurrencesOfString:@"H " withString:@"H'h' "];
    format = [format stringByReplacingOccurrencesOfString:@"H" withString:@"H'h'"
              options:NSBackwardsSearch|NSAnchoredSearch range:NSMakeRange(0, format.length)];
    return format;
}

@interface BRTxHistoryViewController ()

@property (nonatomic, strong) IBOutlet UIView *logo;
@property (nonatomic, strong) IBOutlet UIBarButtonItem *lock;

@property (nonatomic, strong) NSArray *transactions;
@property (nonatomic, assign) BOOL moreTx;
@property (nonatomic, strong) NSMutableDictionary *txDates;
@property (nonatomic, strong) id backgroundObserver, balanceObserver, txStatusObserver;
@property (nonatomic, strong) id syncStartedObserver, syncFinishedObserver, syncFailedObserver;
@property (nonatomic, strong) UIImageView *wallpaper;

@end

@implementation BRTxHistoryViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.txDates = [NSMutableDictionary dictionary];
    self.wallpaper = [[UIImageView alloc] initWithFrame:self.navigationController.view.bounds];
    self.wallpaper.image = [UIImage imageNamed:@"wallpaper-default"];
    self.wallpaper.contentMode = UIViewContentModeScaleAspectFill;
    self.wallpaper.clipsToBounds = YES;
    self.wallpaper.center = CGPointMake(self.wallpaper.frame.size.width/2,
                                        self.navigationController.view.frame.size.height -
                                        self.wallpaper.frame.size.height/2);
    [self.navigationController.view insertSubview:self.wallpaper atIndex:0];
    self.navigationController.delegate = self;
    self.moreTx = YES;
}

-(UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    BRWalletManager *manager = [BRWalletManager sharedInstance];
    
#if SNAPSHOT
    BRTransaction *tx = [[BRTransaction alloc] initWithInputHashes:@[uint256_obj(UINT256_ZERO)] inputIndexes:@[@(0)]
                         inputScripts:@[[NSData data]] outputAddresses:@[@""] outputAmounts:@[@(0)]];
    
    manager.localCurrencyCode = [[NSLocale currentLocale] objectForKey:NSLocaleCurrencyCode];
    self.tableView.showsVerticalScrollIndicator = NO;
    self.moreTx = YES;
    manager.didAuthenticate = YES;
    [self unlock:nil];
    tx.txHash = UINT256_ZERO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self.transactions = @[tx, tx, tx, tx, tx, tx];
        [self.tableView reloadData];
        self.navigationItem.title = [NSString stringWithFormat:@"%@ (%@)", [manager stringForDashAmount:42980000],
                                     [manager localCurrencyStringForDashAmount:42980000]];
    });

    return;
#endif

    if (! manager.didAuthenticate) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            self.transactions = manager.wallet.allTransactions;
           
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
        });
    }
    else [self unlock:nil];

    if (! self.backgroundObserver) {
        self.backgroundObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                self.moreTx = YES;
                self.transactions = manager.wallet.allTransactions;
                [self.tableView reloadData];
                self.navigationItem.titleView = self.logo;
                self.navigationItem.rightBarButtonItem = self.lock;
            }];
    }

    if (! self.balanceObserver) {
        self.balanceObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRWalletBalanceChangedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                BRTransaction *tx = self.transactions.firstObject;

                self.transactions = manager.wallet.allTransactions;

                if (! [self.navigationItem.title isEqual:NSLocalizedString(@"Syncing:", nil)]) {
                    if (! manager.didAuthenticate) self.navigationItem.titleView = self.logo;
                    else [self updateTitleView];
                }

                if (self.transactions.firstObject != tx) {
                    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                     withRowAnimation:UITableViewRowAnimationAutomatic];
                }
                else [self.tableView reloadData];
            }];
    }

    if (! self.txStatusObserver) {
        self.txStatusObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerTxStatusNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                self.transactions = manager.wallet.allTransactions;
                [self.tableView reloadData];
            }];
    }
    
    if (! self.syncStartedObserver) {
        self.syncStartedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncStartedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if ([[BRPeerManager sharedInstance]
                     timestampForBlockHeight:[BRPeerManager sharedInstance].lastBlockHeight] + WEEK_TIME_INTERVAL <
                    [NSDate timeIntervalSinceReferenceDate] &&
                    manager.seedCreationTime + DAY_TIME_INTERVAL < [NSDate timeIntervalSinceReferenceDate]) {
                    self.navigationItem.titleView = nil;
                    self.navigationItem.title = NSLocalizedString(@"Syncing:", nil);
                }
            }];
    }
    
    if (! self.syncFinishedObserver) {
        self.syncFinishedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFinishedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if (! manager.didAuthenticate) self.navigationItem.titleView = self.logo;
                else [self updateTitleView];
            }];
    }
    
    if (! self.syncFailedObserver) {
        self.syncFailedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFailedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if (! manager.didAuthenticate) self.navigationItem.titleView = self.logo;
                [self updateTitleView];
            }];
    }
}


-(UILabel*)titleLabel {
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    UILabel * titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 100)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [titleLabel setBackgroundColor:[UIColor clearColor]];
    NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor]] mutableCopy];
    NSString * titleString = [NSString stringWithFormat:@" (%@)",
                              [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
    [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
    titleLabel.attributedText = attributedDashString;
    return titleLabel;
}

-(void)updateTitleView {
    if (self.navigationItem.titleView && [self.navigationItem.titleView isKindOfClass:[UILabel class]]) {
        BRWalletManager *manager = [BRWalletManager sharedInstance];
        NSMutableAttributedString * attributedDashString = [[manager attributedStringForDashAmount:manager.wallet.balance withTintColor:[UIColor whiteColor]] mutableCopy];
        NSString * titleString = [NSString stringWithFormat:@" (%@)",
                                  [manager localCurrencyStringForDashAmount:manager.wallet.balance]];
        [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString attributes:@{NSForegroundColorAttributeName:[UIColor whiteColor]}]];
        ((UILabel*)self.navigationItem.titleView).attributedText = attributedDashString;
        [((UILabel*)self.navigationItem.titleView) sizeToFit];
    } else {
        self.navigationItem.titleView = [self titleLabel];
    }
}


- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        //BUG: XXX this isn't triggered from start/recover new wallet
        if (self.backgroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.backgroundObserver];
        self.backgroundObserver = nil;
        if (self.balanceObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.balanceObserver];
        self.balanceObserver = nil;
        if (self.txStatusObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.txStatusObserver];
        self.txStatusObserver = nil;
        if (self.syncStartedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncStartedObserver];
        self.syncStartedObserver = nil;
        if (self.syncFinishedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFinishedObserver];
        self.syncFinishedObserver = nil;
        if (self.syncFailedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFailedObserver];
        self.syncFailedObserver = nil;
        self.wallpaper.clipsToBounds = YES;
        
        //self.buyController = nil;
    }

    [super viewWillDisappear:animated];
}

- (void)dealloc
{
    if (self.navigationController.delegate == self) self.navigationController.delegate = nil;
    if (self.backgroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.backgroundObserver];
    if (self.balanceObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.balanceObserver];
    if (self.txStatusObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.txStatusObserver];
    if (self.syncStartedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncStartedObserver];
    if (self.syncFinishedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFinishedObserver];
    if (self.syncFailedObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.syncFailedObserver];
}

- (uint32_t)blockHeight
{
    static uint32_t height = 0;
    uint32_t h = [BRPeerManager sharedInstance].lastBlockHeight;
    
    if (h > height) height = h;
    return height;
}

- (void)setTransactions:(NSArray *)transactions
{
    uint32_t height = self.blockHeight;

    if (! [BRWalletManager sharedInstance].didAuthenticate &&
        [self.navigationItem.title isEqual:NSLocalizedString(@"Syncing:", nil)]) {
        _transactions = @[];
        if (transactions.count > 0) self.moreTx = YES;
    }
    else {
        if (transactions.count <= 5) self.moreTx = NO;
        _transactions = (self.moreTx) ? [transactions subarrayWithRange:NSMakeRange(0, 5)] : [transactions copy];
    
        if (! [BRWalletManager sharedInstance].didAuthenticate) {
            for (BRTransaction *tx in _transactions) {
                if (tx.blockHeight == TX_UNCONFIRMED ||
                    (tx.blockHeight > height - 5 && tx.blockHeight <= height)) continue;
                _transactions = [_transactions subarrayWithRange:NSMakeRange(0, [_transactions indexOfObject:tx])];
                self.moreTx = YES;
                break;
            }
        }
    }
}

- (void)setBackgroundForCell:(UITableViewCell *)cell tableView:(UITableView *)tableView indexPath:(NSIndexPath *)path
{    
    [cell viewWithTag:100].hidden = (path.row > 0);
    [cell viewWithTag:101].hidden = (path.row + 1 < [self tableView:tableView numberOfRowsInSection:path.section]);
}

- (NSString *)dateForTx:(BRTransaction *)tx
{
    static NSDateFormatter *monthDayHourFormatter = nil;
    static NSDateFormatter *yearMonthDayHourFormatter = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{ // BUG: need to watch for NSCurrentLocaleDidChangeNotification
        monthDayHourFormatter = [NSDateFormatter new];
        monthDayHourFormatter.dateFormat = dateFormat(@"Mdjmma");
        yearMonthDayHourFormatter = [NSDateFormatter new];
        yearMonthDayHourFormatter.dateFormat = dateFormat(@"yyMdja");
    });
    
    NSString *date = self.txDates[uint256_obj(tx.txHash)];
    NSTimeInterval now = [[BRPeerManager sharedInstance] timestampForBlockHeight:TX_UNCONFIRMED];
    NSTimeInterval year = [NSDate timeIntervalSinceReferenceDate] - 364*24*60*60;

    if (date) return date;

    NSTimeInterval txTime = (tx.timestamp > 1) ? tx.timestamp : now;
    NSDateFormatter *desiredFormatter = (txTime > year) ? monthDayHourFormatter : yearMonthDayHourFormatter;
    
    date = [desiredFormatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:txTime]];
    if (tx.blockHeight != TX_UNCONFIRMED) self.txDates[uint256_obj(tx.txHash)] = date;
    return date;
}

// MARK: - IBAction

- (IBAction)done:(id)sender
{
    [BREventManager saveEvent:@"tx_history:dismiss"];
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)unlock:(id)sender
{
    BRWalletManager *manager = [BRWalletManager sharedInstance];

    if (sender) [BREventManager saveEvent:@"tx_history:unlock"];
    if (! manager.didAuthenticate) {
        [manager authenticateWithPrompt:nil andTouchId:YES alertIfLockout:YES completion:^(BOOL authenticated, BOOL cancelled) {
            if (authenticated) {
                if (sender) [BREventManager saveEvent:@"tx_history:unlock_success"];
                
                [self updateTitleView];
                [self.navigationItem setRightBarButtonItem:nil animated:(sender) ? YES : NO];
                
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    self.transactions = manager.wallet.allTransactions;
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (sender && self.transactions.count > 0) {
                            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                                          withRowAnimation:UITableViewRowAnimationAutomatic];
                        }
                        else [self.tableView reloadData];
                    });
                });
            }
        }];
    }
}

- (IBAction)scanQR:(id)sender
{
    //TODO: show scanner in settings rather than dismissing
    [BREventManager saveEvent:@"tx_history:scan_qr"];
    UINavigationController *nav = (id)self.navigationController.presentingViewController;

    nav.view.alpha = 0.0;

    [nav dismissViewControllerAnimated:NO completion:^{
        [(id)((BRRootViewController *)nav.viewControllers.firstObject).sendViewController scanQR:nil];
        [UIView animateWithDuration:0.1 delay:1.5 options:0 animations:^{ nav.view.alpha = 1.0; } completion:nil];
    }];
}

- (IBAction)showTx:(id)sender
{
    [BREventManager saveEvent:@"tx_history:show_tx"];
    BRTxDetailViewController *detailController
        = [self.storyboard instantiateViewControllerWithIdentifier:@"TxDetailViewController"];
    detailController.transaction = sender;
    detailController.txDateString = [self dateForTx:sender];
    [self.navigationController pushViewController:detailController animated:YES];
}

- (IBAction)more:(id)sender
{
    [BREventManager saveEvent:@"tx_history:more"];
    BRWalletManager *manager = [BRWalletManager sharedInstance];
    NSUInteger txCount = self.transactions.count;
    
    if (! manager.didAuthenticate) {
        [self unlock:sender];
        return;
    }
    
    [self.tableView beginUpdates];
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:txCount inSection:0]]
     withRowAnimation:UITableViewRowAnimationFade];
    self.moreTx = NO;
    self.transactions = manager.wallet.allTransactions;
    
    NSMutableArray *transactions = [NSMutableArray arrayWithCapacity:self.transactions.count];
    
    while (txCount == 0 || txCount < self.transactions.count) {
        [transactions addObject:[NSIndexPath indexPathForRow:txCount++ inSection:0]];
    }
    
    [self.tableView insertRowsAtIndexPaths:transactions withRowAnimation:UITableViewRowAnimationTop];
    [self.tableView endUpdates];
}

//- (void)showBuyAlert
//{
//    // grab a blurred image for the background
//    UIGraphicsBeginImageContext(self.navigationController.view.bounds.size);
//    [self.navigationController.view drawViewHierarchyInRect:self.navigationController.view.bounds
//                                         afterScreenUpdates:NO];
//    UIImage *bgImg = UIGraphicsGetImageFromCurrentImageContext();
//    UIGraphicsEndImageContext();
//    UIImage *blurredBgImg = [bgImg blurWithRadius:3];
//
//    // display the popup
//    __weak BREventConfirmView *view =
//        [[NSBundle mainBundle] loadNibNamed:@"BREventConfirmView" owner:nil options:nil][0];
//    view.titleLabel.text = NSLocalizedString(@"Buy dash in dashwallet!", nil);
//    view.descriptionLabel.text =
//        NSLocalizedString(@"You can now buy dash in\ndashwallet with cash or\nbank transfer.", nil);
//    [view.okBtn setTitle:NSLocalizedString(@"Try It!", nil) forState:UIControlStateNormal];
//
//    view.image = blurredBgImg;
//    view.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
//    view.frame = self.navigationController.view.bounds;
//    view.alpha = 0;
//    [self.navigationController.view addSubview:view];
//
//    [UIView animateWithDuration:.5 animations:^{
//        view.alpha = 1;
//    }];
//
//    view.completionHandler = ^(BOOL didApprove) {
//        if (didApprove) [self showBuy];
//
//        [UIView animateWithDuration:.5 animations:^{
//            view.alpha = 0;
//        } completion:^(BOOL finished) {
//            [view removeFromSuperview];
//        }];
//    };
//}

// MARK: - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    bool buyEnabled = FALSE;
    switch (section) {
        case 0:
            if (self.transactions.count == 0) return 1;
            return (self.moreTx) ? self.transactions.count + 1 : self.transactions.count;

        case 1:
            return (buyEnabled ? 3 : 2);
    }

    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *noTxIdent = @"NoTxCell", *transactionIdent = @"TransactionCell", *actionIdent = @"ActionCell",
                    *disclosureIdent = @"DisclosureCell";
    UITableViewCell *cell = nil;
    UILabel *textLabel, *unconfirmedLabel, *sentLabel, *localCurrencyLabel, *balanceLabel, *localBalanceLabel,
            *detailTextLabel;
    UIImageView * shapeshiftImageView;
    BRWalletManager *manager = [BRWalletManager sharedInstance];

    switch (indexPath.section) {
        case 0:
            if (self.moreTx && indexPath.row >= self.transactions.count) {
                cell = [tableView dequeueReusableCellWithIdentifier:actionIdent];
                cell.textLabel.text = (indexPath.row > 0) ? NSLocalizedString(@"more...", nil) :
                                      NSLocalizedString(@"transaction history", nil);
                cell.imageView.image = nil;
            }
            else if (self.transactions.count > 0) {
                cell = [tableView dequeueReusableCellWithIdentifier:transactionIdent];
                textLabel = (id)[cell viewWithTag:1];
                detailTextLabel = (id)[cell viewWithTag:2];
                unconfirmedLabel = (id)[cell viewWithTag:3];
                localCurrencyLabel = (id)[cell viewWithTag:5];
                sentLabel = (id)[cell viewWithTag:6];
                balanceLabel = (id)[cell viewWithTag:7];
                localBalanceLabel = (id)[cell viewWithTag:8];
                shapeshiftImageView = (id)[cell viewWithTag:9];

                BRTransaction *tx = self.transactions[indexPath.row];
                uint64_t received = [manager.wallet amountReceivedFromTransaction:tx],
                         sent = [manager.wallet amountSentByTransaction:tx],
                         balance = [manager.wallet balanceAfterTransaction:tx];
                uint32_t blockHeight = self.blockHeight;
                uint32_t confirms = (tx.blockHeight > blockHeight) ? 0 : (blockHeight - tx.blockHeight) + 1;

#if SNAPSHOT
                received = [@[@(0), @(0), @(54000000), @(0), @(0), @(93000000)][indexPath.row] longLongValue];
                sent = [@[@(1010000), @(10010000), @(0), @(82990000), @(10010000), @(0)][indexPath.row] longLongValue];
                balance = [@[@(42980000), @(43990000), @(54000000), @(0), @(82990000), @(93000000)][indexPath.row]
                           longLongValue];
                [self.txDates removeAllObjects];
                tx.timestamp = [NSDate timeIntervalSinceReferenceDate] - indexPath.row*100000;
                confirms = 6;
#endif

                textLabel.textColor = [UIColor darkTextColor];
                sentLabel.hidden = YES;
                unconfirmedLabel.hidden = NO;
                unconfirmedLabel.backgroundColor = [UIColor lightGrayColor];
                detailTextLabel.text = [self dateForTx:tx];
                balanceLabel.attributedText = (manager.didAuthenticate) ? [manager attributedStringForDashAmount:balance withTintColor:balanceLabel.textColor dashSymbolSize:CGSizeMake(9, 9)] : nil;
                localBalanceLabel.text = (manager.didAuthenticate) ? [NSString stringWithFormat:@"(%@)", [manager localCurrencyStringForDashAmount:balance]] : nil;
                shapeshiftImageView.hidden = !tx.associatedShapeshift;

                if (confirms == 0 && ! [manager.wallet transactionIsValid:tx]) {
                    unconfirmedLabel.text = NSLocalizedString(@"INVALID", nil);
                    unconfirmedLabel.backgroundColor = [UIColor redColor];
                    balanceLabel.text = localBalanceLabel.text = nil;
                }
                else if (confirms == 0 && [manager.wallet transactionIsPending:tx]) {
                    unconfirmedLabel.text = NSLocalizedString(@"pending", nil);
                    unconfirmedLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.2];
                    textLabel.textColor = [UIColor grayColor];
                    balanceLabel.text = localBalanceLabel.text = nil;
                }
                else if (confirms == 0 && ! [manager.wallet transactionIsVerified:tx]) {
                    unconfirmedLabel.text = NSLocalizedString(@"unverified", nil);
                }
                else if (confirms < 6) {
                    if (confirms == 0) unconfirmedLabel.text = NSLocalizedString(@"0 confirmations", nil);
                    else if (confirms == 1) unconfirmedLabel.text = NSLocalizedString(@"1 confirmation", nil);
                    else unconfirmedLabel.text = [NSString stringWithFormat:NSLocalizedString(@"%d confirmations", nil),
                                                  (int)confirms];
                }
                else {
                    unconfirmedLabel.text = nil;
                    unconfirmedLabel.hidden = YES;
                    sentLabel.hidden = NO;
                }
                
                if (sent > 0 && received == sent) {
                    textLabel.attributedText = [manager attributedStringForDashAmount:sent];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [manager localCurrencyStringForDashAmount:sent]];
                    sentLabel.text = NSLocalizedString(@"moved", nil);
                    sentLabel.textColor = [UIColor blackColor];
                }
                else if (sent > 0) {
                    textLabel.attributedText = [manager attributedStringForDashAmount:received - sent];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [manager localCurrencyStringForDashAmount:received - sent]];
                    sentLabel.text = NSLocalizedString(@"sent", nil);
                    sentLabel.textColor = [UIColor colorWithRed:1.0 green:0.33 blue:0.33 alpha:1.0];
                }
                else {
                    textLabel.attributedText = [manager attributedStringForDashAmount:received];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [manager localCurrencyStringForDashAmount:received]];
                    sentLabel.text = NSLocalizedString(@"received", nil);
                    sentLabel.textColor = [UIColor colorWithRed:255.0 green:255.75 blue:255.0 alpha:1.0];
                }

                if (! unconfirmedLabel.hidden) {
                    unconfirmedLabel.layer.cornerRadius = 3.0;
                    unconfirmedLabel.text = [unconfirmedLabel.text stringByAppendingString:@"  "];
                }
                else {
                    sentLabel.layer.cornerRadius = 3.0;
                    sentLabel.layer.borderWidth = 0.8;
                    sentLabel.text = [sentLabel.text stringByAppendingString:@"  "];
                    sentLabel.layer.borderColor = sentLabel.textColor.CGColor;
                    sentLabel.highlightedTextColor = sentLabel.textColor;
                }
            }
            else cell = [tableView dequeueReusableCellWithIdentifier:noTxIdent];
            
            break;

        case 1:
            cell = [tableView dequeueReusableCellWithIdentifier:actionIdent];
            bool buyEnabled = FALSE;
            long adjustedRow = !buyEnabled ? indexPath.row + 1 : indexPath.row;
            switch (adjustedRow) {
                case 0:
                    cell.textLabel.text = NSLocalizedString(@"Buy Dash", nil);
                    cell.imageView.image = [UIImage imageNamed:@"dash-buy-blue-small"];
                    break;
                    
                case 1:
                    cell.textLabel.text = NSLocalizedString(@"import private key", nil);
                    cell.imageView.image = [UIImage imageNamed:@"cameraguide-blue-small"];
                    break;

                case 2:
                    cell = [tableView dequeueReusableCellWithIdentifier:disclosureIdent];
                    cell.textLabel.text = NSLocalizedString(@"settings", nil);
                    cell.imageView.image = [UIImage imageNamed:@"settings"];
                    break;
            }
            
            break;
    }
    
    [self setBackgroundForCell:cell tableView:tableView indexPath:indexPath];
    return cell;
}

// MARK: - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case 0: return (self.moreTx && indexPath.row >= self.transactions.count) ? 44.0 : TRANSACTION_CELL_HEIGHT;
        case 1: return 44.0;
    }
    
    return 44.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *sectionTitle = [self tableView:tableView titleForHeaderInSection:section];

    if (sectionTitle.length == 0) return 22.0;

    CGRect r = [sectionTitle boundingRectWithSize:CGSizeMake(self.view.frame.size.width - 20.0, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:[UIFont systemFontOfSize:13]} context:nil];
    
    return r.size.height + 22.0 + 10.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width,
                                                         [self tableView:tableView heightForHeaderInSection:section])];
    UILabel *l = [UILabel new];
    CGRect r = CGRectMake(15.0, 0.0, v.frame.size.width - 20.0, v.frame.size.height - 22.0);
    
    l.text = [self tableView:tableView titleForHeaderInSection:section];
    l.backgroundColor = [UIColor clearColor];
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor grayColor];
    l.shadowColor = [UIColor whiteColor];
    l.shadowOffset = CGSizeMake(0.0, 1.0);
    l.numberOfLines = 0;
    r.size.width = [l sizeThatFits:r.size].width;
    r.origin.x = (self.view.frame.size.width - r.size.width)/2;
    if (r.origin.x < 15.0) r.origin.x = 15.0;
    l.frame = r;
    v.backgroundColor = [UIColor clearColor];
    [v addSubview:l];

    return v;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    return (section + 1 == [self numberOfSectionsInTableView:tableView]) ? 22.0 : 0.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width,
                                                         [self tableView:tableView heightForFooterInSection:section])];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    //TODO: include an option to generate a new wallet and sweep old balance if backup may have been compromized
    UIViewController *destinationController = nil;

    switch (indexPath.section) {
        case 0: // transaction
            if (self.moreTx && indexPath.row >= self.transactions.count) { // more...
                [self performSelector:@selector(more:) withObject:tableView afterDelay:0.0];
            }
            else if (self.transactions.count > 0) [self showTx:self.transactions[indexPath.row]]; // transaction details

            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            break;

        case 1:
        {
            bool buyEnabled = FALSE;//[[BRAPIClient sharedClient] featureEnabled:BRFeatureFlagsBuyDash];
            long adjustedRow = !buyEnabled ? indexPath.row + 1 : indexPath.row;
            switch (adjustedRow) {
                case 0: // buy dash
                    [BREventManager saveEvent:@"tx_history:buy_btc"];
                    [tableView deselectRowAtIndexPath:indexPath animated:YES];
                    //[self showBuy];
                    break;
                    
                case 1: // import private key
                    [BREventManager saveEvent:@"tx_history:import_priv_key"];
                    [self scanQR:nil];
                    break;

                case 2: // settings
                    [BREventManager saveEvent:@"tx_history:settings"];
                    destinationController = [self.storyboard instantiateViewControllerWithIdentifier:@"SettingsViewController"];
                    [self.navigationController pushViewController:destinationController animated:YES];
                    break;
            }

            break;
        }
    }
}

// MARK: - UIViewControllerAnimatedTransitioning

// This is used for percent driven interactive transitions, as well as for container controllers that have companion
// animations that might need to synchronize with the main animation.
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext
{
    return 0.35;
}

// This method can only be a nop if the transition is interactive and not a percentDriven interactive transition.
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    UIView *containerView = transitionContext.containerView;
    UIViewController *to = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey],
                     *from = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    BOOL pop = (to == self || (from != self && [to isKindOfClass:[BRSettingsViewController class]])) ? YES : NO;

    if (self.wallpaper.superview != containerView) [containerView insertSubview:self.wallpaper belowSubview:from.view];
    self.wallpaper.clipsToBounds = NO;
    to.view.center = CGPointMake(containerView.frame.size.width*(pop ? -1 : 3)/2, to.view.center.y);
    [containerView addSubview:to.view];

    [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
    initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        to.view.center = from.view.center;
        from.view.center = CGPointMake(containerView.frame.size.width*(pop ? 3 : -1)/2, from.view.center.y);
        self.wallpaper.center = CGPointMake(self.wallpaper.frame.size.width/2 -
                                            containerView.frame.size.width*(pop ? 0 : 1)*PARALAX_RATIO,
                                            self.wallpaper.center.y);
    } completion:^(BOOL finished) {
        if (pop) [from.view removeFromSuperview];
        [transitionContext completeTransition:YES];
    }];
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

@end
