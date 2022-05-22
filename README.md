# hodler-vault

Set of contract that automates the strategy of holding crypto, at the same time investing borrowed stablecoins, with insurance-based liquidation protection. 

## Problem 

There are different projects that are willing to attract liquidity in stable coins and give yields in stable coins. At the same time, a big chunk of crypto wealth it's in volatile crypto assets like BTC, ETH or
MATIC. The holders of those volatile crypto assets want to stay in those assets expecting future appreciation (hodler strategy). The yields staying in the volatile crypto assets are low. It's possible to deposit the crypto assets in lending platforms like AAVE or Maker, and borrow stable coins, but this strategy requires continuous administration and it's exposed to liquidation risk.

## Solution

The Hodler vault is an ERC-4626 compatible vault that manages this process of depositing crypto into AAVE, borrowing stable coins, and investing those stables into an underlying protocol that gives a yield bigger than AAVE's borrow rate. At the same time, it keeps the funds protected from liquidation risk. 

## How it works 

The vault has two parameters: invest health factor and de-invest health factor, for example, 1.4 and 1.3. Every crypto that is deposited into the vault, it's immediately deposited into AAVE. 

If the health factor is greater than *invest health factor*, it borrows more stable up to leave the account in *invest health factor* and invests those assets into the underlying protocol. 

If the health factor is lower than *de-invest health factor*, it de-invests from the underlying protocol and repays the loan, leaving the account again in *invest health factor*.

At the same time, given the price fluctuations might be fast and given in some cases the underlying protocol might now allow withdraws, there is a liquidation protection mechanism in place. 

There are other two parameters: trigger health factor and safe health factor, for example, 1.02 and 1.1. On the insure endpoint the vault acquires a policy from Ensuro's Price Risk Module, that's triggered if the price of the crypto assets is below the price that corresponds to trigger health factor. The payout received from this policy will be in stable coins, this amount will be used to acquire the crypto assets (buy the dip) and deposit them into AAVE to increase the health factor (should be enough to take it to safe health factor). 
