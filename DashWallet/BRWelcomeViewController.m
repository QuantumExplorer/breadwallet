//
//  BRWelcomeViewController.m
//  BreadWallet
//
//  Created by Aaron Voisine on 7/8/13.
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

#import "BRWelcomeViewController.h"
#import "BRRootViewController.h"
#import "BRWalletManager.h"
#import "BREventManager.h"


@interface BRWelcomeViewController ()

@property (nonatomic, assign) BOOL hasAppeared, animating;
@property (nonatomic, strong) id foregroundObserver, backgroundObserver;

@property (nonatomic, strong) IBOutlet UIView *wallpaper, *wallpaperContainer;
@property (nonatomic, strong) IBOutlet UIButton *newwalletButton, *recoverButton;
@property (nonatomic, strong) IBOutlet NSLayoutConstraint *logoXCenter, *walletXCenter, *restoreXCenter,
                                                           *wallpaperXLeft;

@end


@implementation BRWelcomeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view.
        
    self.navigationController.delegate = self;

    self.newwalletButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.recoverButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    self.newwalletButton.titleLabel.adjustsLetterSpacingToFitWidth = YES;
    self.recoverButton.titleLabel.adjustsLetterSpacingToFitWidth = YES;
    self.newwalletButton.layer.cornerRadius = 0.15 * self.newwalletButton.bounds.size.height;
    self.newwalletButton.layer.borderWidth = 1.0;
    self.recoverButton.layer.cornerRadius = 0.15 * self.recoverButton.bounds.size.height;
    self.recoverButton.layer.borderWidth = 1.0;
#pragma clang diagnostic pop

    self.foregroundObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            [self animateWallpaper];
        }];
    
    self.backgroundObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:nil usingBlock:^(NSNotification *note) {
            self.wallpaperXLeft.constant = 0;
            [self.wallpaper.superview layoutIfNeeded];
        }];
}

- (void)dealloc
{
    if (self.navigationController.delegate == self) self.navigationController.delegate = nil;
    if (self.foregroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.foregroundObserver];
    if (self.backgroundObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.backgroundObserver];
}

-(UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

-(BOOL)prefersStatusBarHidden {
    return FALSE;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    if (self.hasAppeared) {
        self.logoXCenter.constant = self.view.frame.size.width;
        self.navigationItem.titleView.hidden = NO;
    }
    else {
        self.walletXCenter.constant = -self.view.frame.size.width;
        self.restoreXCenter.constant = -self.view.frame.size.width;
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [BREventManager saveEvent:@"welcome:shown"];

    dispatch_async(dispatch_get_main_queue(), ^{ // animation sometimes doesn't work if run directly in viewDidAppear
#if SNAPSHOT
        [[UIApplication sharedApplication] setStatusBarHidden:NO];
        self.navigationItem.titleView.hidden = NO;
        self.navigationItem.titleView.alpha = 1.0;
        self.logoXCenter.constant = self.view.frame.size.width;
        self.walletXCenter.constant = self.restoreXCenter.constant = 0.0;
        return;
#endif

        if (! [BRWalletManager sharedInstance].noWallet) { // sanity check
            [self.navigationController.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        }

        if (! self.hasAppeared) {
            [self.wallpaperContainer removeFromSuperview];
            [self.navigationController.view insertSubview:self.wallpaperContainer atIndex:0];
            [self.navigationController.view
             addConstraint:[NSLayoutConstraint constraintWithItem:self.navigationController.view
                                                        attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:self.wallpaperContainer
                                                        attribute:NSLayoutAttributeBottom multiplier:1.0 constant:0.0]];
            [self.navigationController.view
             addConstraint:[NSLayoutConstraint constraintWithItem:self.navigationController.view
                                                        attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual toItem:self.wallpaperContainer
                                                        attribute:NSLayoutAttributeTop multiplier:1.0 constant:0.0]];
            self.hasAppeared = YES;
            self.logoXCenter.constant = self.view.frame.size.width;
            self.walletXCenter.constant = 0.0;
            self.restoreXCenter.constant = 0.0;
            self.navigationItem.titleView.hidden = NO;
            self.navigationItem.titleView.alpha = 0.0;

            [UIView animateWithDuration:0.35 delay:1.0 usingSpringWithDamping:0.8 initialSpringVelocity:0.0
            options:UIViewAnimationOptionCurveEaseOut animations:^{
                self.navigationItem.titleView.alpha = 1.0;
                [self.navigationController.view layoutIfNeeded];
            } completion:nil];
        }

        [self animateWallpaper];
    });
}

- (void)animateWallpaper
{
    if (self.animating) return;
    self.animating = YES;

    self.wallpaperXLeft.constant = -240.0;

    [UIView animateWithDuration:30.0 delay:0.0
    options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse
    animations:^{
        [self.wallpaperContainer layoutIfNeeded];
    } completion:^(BOOL finished) {
        self.animating = NO;
    }];
}

// MARK: IBAction

- (IBAction)start:(id)sender
{
    [BREventManager saveEvent:@"welcome:new_wallet"];
    
    UIViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"GenerateViewController"];
    
    [self.navigationController pushViewController:c animated:YES];
}

- (IBAction)recover:(id)sender
{
    [BREventManager saveEvent:@"welcome:recover_wallet"];

    UIViewController *c = [self.storyboard instantiateViewControllerWithIdentifier:@"RecoverViewController"];

    [self.navigationController pushViewController:c animated:YES];
}

// MARK: UIViewControllerAnimatedTransitioning

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

    to.view.center = CGPointMake(v.frame.size.width*(to == self ? -1 : 3)/2.0, to.view.center.y);
    [v addSubview:to.view];
    [v layoutIfNeeded];
    
    [UIView animateWithDuration:[self transitionDuration:transitionContext] delay:0.0 usingSpringWithDamping:0.8
    initialSpringVelocity:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        to.view.center = from.view.center;
        from.view.center = CGPointMake(v.frame.size.width*(to == self ? 3 : -1)/2.0, from.view.center.y);
//        [self.navigationController.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        if (to == self) [from.view removeFromSuperview];
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

//TODO: implement interactive transitions

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
