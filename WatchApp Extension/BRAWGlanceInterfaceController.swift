//
//  BRAWGlanceInterfaceController.swift
//  DashWallet
//
//  Created by Henry on 10/27/15.
//  Copyright (c) 2015 Aaron Voisine <voisine@gmail.com>
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

import WatchKit

final class BRAWGlanceInterfaceController: WKInterfaceController {
    @IBOutlet private var setupWalletContainer: WKInterfaceGroup!
    @IBOutlet private var balanceAmountLabel: WKInterfaceLabel!
    @IBOutlet private var balanceInLocalCurrencyLabel: WKInterfaceLabel!
    @IBOutlet private var lastTransactionLabel: WKInterfaceLabel!
    @IBOutlet private var balanceInfoContainer: WKInterfaceGroup!
    @IBOutlet private var loadingIndicator: WKInterfaceGroup!

    override func awake(withContext context: Any?) {
        super.awake(withContext: context)
        // Configure interface objects here.
        updateUI()
    }

    override func willActivate() {
        // This method is called when watch view controller is about to be visible to user
        super.willActivate()
        BRAWWatchDataManager.sharedInstance.setupTimer()
        updateUI()
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(BRAWGlanceInterfaceController.updateUI),
            name: BRAWWatchDataManager.ApplicationDataDidUpdateNotification,
            object: nil
        )
    }

    override func didDeactivate() {
        // This method is called when watch view controller is no longer visible
        super.didDeactivate()
        BRAWWatchDataManager.sharedInstance.destoryTimer()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    func updateUI() {
        if Thread.current != .main {
            DispatchQueue.main.async {
                self.updateUI()
            }

            return
        }

        // when local currency rate is no avaliable, use empty string
        updateContainerVisibility()

        let dataManager = BRAWWatchDataManager.sharedInstance
        let balanceInLocalCurrency = dataManager.balanceInLocalCurrency
        if let balanceInLocalCurrency = balanceInLocalCurrency, balanceInLocalCurrency.count > 2 {
            balanceInLocalCurrencyLabel.setHidden(false)
        }
        else {
            balanceInLocalCurrencyLabel.setHidden(true)
        }
        balanceAmountLabel.setAttributedText(dataManager.balanceAttributedString())
        balanceInLocalCurrencyLabel.setText(balanceInLocalCurrency)
        lastTransactionLabel.setText(dataManager.lastestTransction)
    }

    func shouldShowSetupWalletInterface() -> Bool {
        return false
    }

    func updateContainerVisibility() {
        switch BRAWWatchDataManager.sharedInstance.walletStatus {
        case .unknown:
            loadingIndicator.setHidden(false)
            balanceInfoContainer.setHidden(true)
            setupWalletContainer.setHidden(true)
        case .notSetup:
            loadingIndicator.setHidden(true)
            balanceInfoContainer.setHidden(true)
            setupWalletContainer.setHidden(false)
        case .hasSetup:
            loadingIndicator.setHidden(true)
            balanceInfoContainer.setHidden(false)
            setupWalletContainer.setHidden(true)
        }
    }
}
