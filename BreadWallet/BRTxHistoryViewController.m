//
//  BRTxHistoryViewController.m
//  DashWallet
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

#define TRANSACTION_CELL_HEIGHT 75

static NSString *dateFormat(NSString *template)
{
    NSString *format = [NSDateFormatter dateFormatFromTemplate:template options:0 locale:[NSLocale currentLocale]];
    
    format = [format stringByReplacingOccurrencesOfString:@", " withString:@" "];
    format = [format stringByReplacingOccurrencesOfString:@" a" withString:@"a"];
    format = [format stringByReplacingOccurrencesOfString:@"hh" withString:@"h"];
    format = [format stringByReplacingOccurrencesOfString:@" ha" withString:@"@ha"];
    format = [format stringByReplacingOccurrencesOfString:@"HH" withString:@"H"];
    format = [format stringByReplacingOccurrencesOfString:@"H 'h'" withString:@"H'h'"];
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
    self.wallpaper.contentMode = UIViewContentModeLeft;
    self.wallpaper.clipsToBounds = YES;
    [self.navigationController.view insertSubview:self.wallpaper atIndex:0];
    self.navigationController.delegate = self;
    self.moreTx = YES;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:YES];
    
    BRWalletManager *m = [BRWalletManager sharedInstance];
    
    if (m.didAuthenticate) [self unlock:nil];
    self.transactions = m.wallet.recentTransactions;

    if (! self.backgroundObserver) {
        self.backgroundObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
            object:nil queue:nil usingBlock:^(NSNotification *note) {
                self.moreTx = YES;
                self.transactions = m.wallet.recentTransactions;
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

                self.transactions = m.wallet.recentTransactions;

                if (! [self.navigationItem.title isEqual:NSLocalizedString(@"syncing...", nil)]) {
                    if (! m.didAuthenticate) self.navigationItem.titleView = self.logo;
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
                [self.tableView reloadData];
            }];
    }
    
    if (! self.syncStartedObserver) {
        self.syncStartedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncStartedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if ([[BRPeerManager sharedInstance]
                     timestampForBlockHeight:[[BRPeerManager sharedInstance] lastBlockHeight]] + WEEK_TIME_INTERVAL <
                    [NSDate timeIntervalSinceReferenceDate] &&
                    m.seedCreationTime + 60*60*24 < [NSDate timeIntervalSinceReferenceDate]) {
                    self.navigationItem.titleView = nil;
                    self.navigationItem.title = NSLocalizedString(@"syncing...", nil);
                }
            }];
    }
    
    if (! self.syncFinishedObserver) {
        self.syncFinishedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFinishedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if (! m.didAuthenticate) self.navigationItem.titleView = self.logo;
                else [self updateTitleView];
            }];
    }
    
    if (! self.syncFailedObserver) {
        self.syncFailedObserver =
            [[NSNotificationCenter defaultCenter] addObserverForName:BRPeerManagerSyncFailedNotification object:nil
            queue:nil usingBlock:^(NSNotification *note) {
                if (! m.didAuthenticate) self.navigationItem.titleView = self.logo;
                else [self updateTitleView];
            }];
    }
}

-(void)updateTitleView {
    BRWalletManager *m = [BRWalletManager sharedInstance];
    UILabel * titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 1, 100)];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [titleLabel setBackgroundColor:[UIColor clearColor]];
    NSMutableAttributedString * attributedDashString = [[m attributedDashStringForAmount:m.wallet.balance] mutableCopy];
    NSString * titleString = [NSString stringWithFormat:@" (%@)",
                              [m localCurrencyStringForDashAmount:m.wallet.balance]];
    [attributedDashString appendAttributedString:[[NSAttributedString alloc] initWithString:titleString]];
    titleLabel.attributedText = attributedDashString;
    self.navigationItem.titleView = titleLabel;
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
    }

    [super viewWillDisappear:animated];
}

//- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
//{
//    [super prepareForSegue:segue sender:sender];
//
//    [segue.destinationViewController setTransitioningDelegate:self];
//    [segue.destinationViewController setModalPresentationStyle:UIModalPresentationCustom];
//}

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
    uint32_t h = [[BRPeerManager sharedInstance] lastBlockHeight];
    
    if (h > height) height = h;
    return height;
}

- (void)setTransactions:(NSArray *)transactions
{
    uint32_t height = self.blockHeight;

    if (transactions.count <= 5) self.moreTx = NO;
    _transactions = [transactions subarrayWithRange:NSMakeRange(0, (self.moreTx) ? 5 : transactions.count)];
    if ([[BRWalletManager sharedInstance] didAuthenticate]) return;
    
    for (BRTransaction *tx in _transactions) {
        if (tx.blockHeight == TX_UNCONFIRMED || (tx.blockHeight > height - 5 && tx.blockHeight <= height)) continue;
        _transactions = [transactions subarrayWithRange:NSMakeRange(0, [transactions indexOfObject:tx])];
        self.moreTx = YES;
        break;
    }
}

- (void)setBackgroundForCell:(UITableViewCell *)cell tableView:(UITableView *)tableView indexPath:(NSIndexPath *)path
{
    if (! cell.backgroundView) {
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cell.frame.size.width, 0.5)];
        
        v.tag = 100;
        cell.backgroundView = [[UIView alloc] initWithFrame:cell.frame];
        cell.backgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.67];
        v.backgroundColor = tableView.separatorColor;
        [cell.backgroundView addSubview:v];
        v = [[UIView alloc] initWithFrame:CGRectMake(0, cell.frame.size.height - 0.5, cell.frame.size.width, 0.5)];
        v.tag = 101;
        v.backgroundColor = tableView.separatorColor;
        [cell.backgroundView addSubview:v];
    }
    
    [cell viewWithTag:100].frame = CGRectMake((path.row == 0 ? 0 : 15), 0, cell.frame.size.width, 0.5);
    [cell viewWithTag:101].hidden = (path.row + 1 < [self tableView:tableView numberOfRowsInSection:path.section]);
}

- (NSString *)dateForTx:(BRTransaction *)tx
{
    static NSDateFormatter *f1 = nil, *f2 = nil, *f3 = nil, *f4 = nil;
    NSString *date = self.txDates[tx.txHash];
    NSTimeInterval now = [[BRPeerManager sharedInstance] timestampForBlockHeight:TX_UNCONFIRMED],
                   week = now - 6*24*60*60, year = now - 364*24*60*60;

    if (date) return date;

    if (! f1) { //BUG: need to watch for NSCurrentLocaleDidChangeNotification
        f1 = [NSDateFormatter new];
        f1.dateFormat = dateFormat(@"Mdjmma");
        f2 = [NSDateFormatter new];
        f2.dateFormat = dateFormat(@"yyMdja");
        f3 = [NSDateFormatter new];
        f3.dateFormat = dateFormat(@"Md");
        f4 = [NSDateFormatter new];
        f4.dateFormat = dateFormat(@"yyMd");
    }
    
    NSTimeInterval t = (tx.timestamp > 1) ? tx.timestamp :
                       [[BRPeerManager sharedInstance] timestampForBlockHeight:tx.blockHeight] - 5*60;
    NSDateFormatter *f = (t > year) ? f1 : f2;
    
    if (tx.timestamp <= 1 && t <= week) f = (t > year) ? f3 : f4;

    date = [[f stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:t]] lowercaseString];
    if (tx.blockHeight != TX_UNCONFIRMED) self.txDates[tx.txHash] = date;
    return date;
}

#pragma mark - IBAction

- (IBAction)done:(id)sender
{
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (IBAction)unlock:(id)sender
{
    BRWalletManager *m = [BRWalletManager sharedInstance];

    if (! m.didAuthenticate && ! [m authenticateWithPrompt:nil andTouchId:YES]) return;
    
    [self updateTitleView];
    [self.navigationItem setRightBarButtonItem:nil animated:(sender) ? YES : NO];
    if (self.transactions.count > 0) [self.tableView reloadData];
    if (sender) self.transactions = m.wallet.recentTransactions;
    
    if (sender && self.transactions.count > 0) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
         withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

- (IBAction)scanQR:(id)sender
{
    //TODO: show scanner in settings rather than dismissing
    UINavigationController *nav = (id)self.navigationController.presentingViewController;

    nav.view.alpha = 0.0;

    [nav dismissViewControllerAnimated:NO completion:^{
        [(id)[nav.viewControllers.firstObject sendViewController] scanQR:nil];
        [UIView animateWithDuration:0.1 delay:1.5 options:0 animations:^{ nav.view.alpha = 1.0; } completion:nil];
    }];
}

- (IBAction)showTx:(id)sender
{
    BRTxDetailViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"TxDetailViewController"];
    c.transaction = sender;
    c.txDateString = [self dateForTx:sender];
    [self.navigationController pushViewController:c animated:YES];
}

- (IBAction)more:(id)sender
{
    BRWalletManager *m = [BRWalletManager sharedInstance];
    NSUInteger i = self.transactions.count;
    
    [self unlock:nil];
    if (! m.didAuthenticate) return;
    
    [self.tableView beginUpdates];
    [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:i inSection:0]]
     withRowAnimation:UITableViewRowAnimationFade];
    self.moreTx = NO;
    self.transactions = m.wallet.recentTransactions;
    
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:self.transactions.count];
    
    while (i < self.transactions.count) {
        [a addObject:[NSIndexPath indexPathForRow:i++ inSection:0]];
    }
    
    [self.tableView insertRowsAtIndexPaths:a withRowAnimation:UITableViewRowAnimationTop];
    [self.tableView endUpdates];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0:
            if (self.transactions.count == 0) return 1;
            return (self.moreTx) ? self.transactions.count + 1 : self.transactions.count;

        case 1:
            return 2;

        case 2:
            return 1;
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
    BRWalletManager *m = [BRWalletManager sharedInstance];

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
                uint64_t received = [m.wallet amountReceivedFromTransaction:tx],
                         sent = [m.wallet amountSentByTransaction:tx],
                         balance = [m.wallet balanceAfterTransaction:tx];
                uint32_t h = self.blockHeight, confirms = (tx.blockHeight > h) ? 0 : (h - tx.blockHeight) + 1;

                sentLabel.hidden = YES;
                unconfirmedLabel.hidden = NO;
                detailTextLabel.text = [self dateForTx:tx];
                balanceLabel.attributedText = (m.didAuthenticate) ? [m attributedDashStringForAmount:balance withTintColor:balanceLabel.textColor dashSymbolSize:CGSizeMake(9, 9)] : nil;
                localBalanceLabel.text = (m.didAuthenticate) ?
                    [NSString stringWithFormat:@"(%@)", [m localCurrencyStringForDashAmount:balance]] : nil;
                shapeshiftImageView.hidden = !tx.associatedShapeshift;

                if (confirms == 0 && ! [m.wallet transactionIsValid:tx]) {
                    unconfirmedLabel.text = NSLocalizedString(@"INVALID", nil);
                    unconfirmedLabel.backgroundColor = [UIColor redColor];
                }
                else if (confirms == 0 && [m.wallet transactionIsPostdated:tx atBlockHeight:h]) {
                    unconfirmedLabel.text = NSLocalizedString(@"post-dated", nil);
                    unconfirmedLabel.backgroundColor = [UIColor redColor];
                }
                else if (confirms == 0 && tx.timestamp < 1) { // timestamp gets set when tx is first verified
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
                    textLabel.attributedText = [m attributedDashStringForAmount:sent];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [m localCurrencyStringForDashAmount:sent]];
                    sentLabel.text = NSLocalizedString(@"moved", nil);
                    sentLabel.textColor = [UIColor blackColor];
                }
                else if (sent > 0) {
                    textLabel.attributedText = [m attributedDashStringForAmount:received - sent];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [m localCurrencyStringForDashAmount:received - sent]];
                    sentLabel.text = NSLocalizedString(@"sent", nil);
                    sentLabel.textColor = [UIColor colorWithRed:1.0 green:0.33 blue:0.33 alpha:1.0];
                }
                else {
                    textLabel.attributedText = [m attributedDashStringForAmount:received];
                    localCurrencyLabel.text = [NSString stringWithFormat:@"(%@)",
                                               [m localCurrencyStringForDashAmount:received]];
                    sentLabel.text = NSLocalizedString(@"received", nil);
                    sentLabel.textColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.0 alpha:1.0];
                }

                if (! unconfirmedLabel.hidden) {
                    unconfirmedLabel.layer.cornerRadius = 3.0;
                    unconfirmedLabel.backgroundColor = [UIColor lightGrayColor];
                    unconfirmedLabel.text = [unconfirmedLabel.text stringByAppendingString:@"  "];
                }
                else {
                    sentLabel.layer.cornerRadius = 3.0;
                    sentLabel.layer.borderWidth = 0.5;
                    sentLabel.text = [sentLabel.text stringByAppendingString:@"  "];
                    sentLabel.layer.borderColor = sentLabel.textColor.CGColor;
                    sentLabel.highlightedTextColor = sentLabel.textColor;
                }
            }
            else cell = [tableView dequeueReusableCellWithIdentifier:noTxIdent];
            
            break;

        case 1:
            cell = [tableView dequeueReusableCellWithIdentifier:actionIdent];

            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text = NSLocalizedString(@"import private key", nil);
                    cell.imageView.image = [UIImage imageNamed:@"cameraguide-blue-small"];
                    cell.imageView.alpha = 1.0;
                    break;

                case 1:
                    cell.textLabel.text = NSLocalizedString(@"rescan blockchain", nil);
                    cell.imageView.image = [UIImage imageNamed:@"rescan"];
                    cell.imageView.alpha = 0.75;
                    break;
            }
            
            break;

        case 2:
            cell = [tableView dequeueReusableCellWithIdentifier:disclosureIdent];
            cell.textLabel.text = NSLocalizedString(@"settings", nil);
            break;
    }
    
    [self setBackgroundForCell:cell tableView:tableView indexPath:indexPath];
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0:
            return nil;

        case 1:
            return nil;
            
        case 2:
            return NSLocalizedString(@"rescan blockchain if you think you may have missing transactions, "
                                     "or are having trouble sending (rescanning can take several minutes)", nil);
    }
    
    return nil;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case 0: return (self.moreTx && indexPath.row >= self.transactions.count) ? 44.0 : TRANSACTION_CELL_HEIGHT;
        case 1: return 44.0;
        case 2: return 44.0;
    }
    
    return 44.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    NSString *s = [self tableView:tableView titleForHeaderInSection:section];

    if (s.length == 0) return 22.0;

    CGRect r = [s boundingRectWithSize:CGSizeMake(self.view.frame.size.width - 20.0, CGFLOAT_MAX)
                options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{NSFontAttributeName:[UIFont fontWithName:@"HelveticaNeue" size:13]} context:nil];
    
    return r.size.height + 22.0 + 10.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width,
                                                         [self tableView:tableView heightForHeaderInSection:section])];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(15.0, 0.0, v.frame.size.width - 20.0,
                                                           v.frame.size.height - 22.0)];
    
    l.text = [self tableView:tableView titleForHeaderInSection:section];
    l.backgroundColor = [UIColor clearColor];
    l.font = [UIFont fontWithName:@"HelveticaNeue" size:13];
    l.textColor = [UIColor blackColor];
    l.numberOfLines = 0;
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
    UIViewController *c = nil;

    switch (indexPath.section) {
        case 0: // transaction
            if (self.moreTx && indexPath.row >= self.transactions.count) { // more...
                [self performSelector:@selector(more:) withObject:nil afterDelay:0.0];
            }
            else if (self.transactions.count > 0) [self showTx:self.transactions[indexPath.row]]; // transaction details

            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            break;

        case 1:
            switch (indexPath.row) {
                case 0: // import private key
                    [self scanQR:nil];
                    break;

                case 1: // rescan blockchain
                    [[BRPeerManager sharedInstance] rescan];
                    [self done:nil];
                    break;
            }

            break;

        case 2: // settings
            c = [self.storyboard instantiateViewControllerWithIdentifier:@"SettingsViewController"];
            [self.navigationController pushViewController:c animated:YES];
            break;
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) {
        [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
        return;
    }

    BRSeedViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"SeedViewController"];
    
    if (c.authSuccess) {
        [self.navigationController pushViewController:c animated:YES];
    }
    else [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
}

#pragma mark - UIViewControllerAnimatedTransitioning

// This is used for percent driven interactive transitions, as well as for container controllers that have companion
// animations that might need to synchronize with the main animation.
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)transitionContext
{
    return 0.35;
}

// This method can only be a nop if the transition is interactive and not a percentDriven interactive transition.
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    UIView *v = transitionContext.containerView;
    UIViewController *to = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey],
                     *from = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    BOOL pop = (to == self || (from != self && [to isKindOfClass:[BRSettingsViewController class]])) ? YES : NO;

    if (self.wallpaper.superview != v) [v insertSubview:self.wallpaper belowSubview:from.view];
    self.wallpaper.clipsToBounds = NO;
    to.view.center = CGPointMake(v.frame.size.width*(pop ? -1 : 3)/2, to.view.center.y);
    [v addSubview:to.view];

    [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
    initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        to.view.center = from.view.center;
        from.view.center = CGPointMake(v.frame.size.width*(pop ? 3 : -1)/2, from.view.center.y);
        self.wallpaper.center = CGPointMake(self.wallpaper.frame.size.width/2 -
                                            v.frame.size.width*(pop ? 0 : 1)*PARALAX_RATIO, self.wallpaper.center.y);
    } completion:^(BOOL finished) {
        if (pop) [from.view removeFromSuperview];
        [transitionContext completeTransition:YES];
    }];
}

#pragma mark - UINavigationControllerDelegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)fromVC
toViewController:(UIViewController *)toVC
{
    return self;
}

#pragma mark - UIViewControllerTransitioningDelegate

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
