;; Minimum collateralization ratio (150%)
(define-constant MIN_COLLATERAL_RATIO u150)

;; Liquidation threshold (120%)
(define-constant LIQUIDATION_THRESHOLD u120)

;; Liquidation penalty (10%)
(define-constant LIQUIDATION_PENALTY u10)

;; Maximum loan-to-value ratio (66%)
(define-constant MAX_LTV u66)

;; Interest rate model parameters
(define-constant BASE_RATE u200)  ;; 2% base rate
(define-constant RATE_SLOPE_1 u400)  ;; 4% rate increase per utilization up to optimal
(define-constant RATE_SLOPE_2 u2000)  ;; 20% rate increase per utilization above optimal
(define-constant OPTIMAL_UTILIZATION u800)  ;; 80% optimal utilization

;; Protocol fee (10% of interest)
(define-constant PROTOCOL_FEE u10)

;; Reserve factor (20% of interest goes to reserves)
(define-constant RESERVE_FACTOR u20)

;; Time periods
(define-constant SECONDS_PER_YEAR u31536000)
(define-constant INTEREST_UPDATE_PERIOD u86400)  ;; 24 hours

;; Error codes
(define-constant ERR_UNAUTHORIZED u1)
(define-constant ERR_INSUFFICIENT_COLLATERAL u2)
(define-constant ERR_INVALID_AMOUNT u3)
(define-constant ERR_ASSET_NOT_SUPPORTED u4)
(define-constant ERR_LOAN_NOT_FOUND u5)
(define-constant ERR_INSUFFICIENT_LIQUIDITY u6)
(define-constant ERR_BELOW_MIN_COLLATERAL u7)

(define-constant ERR_NOT_LIQUIDATABLE u8)
(define-constant ERR_PRICE_FEED_ERROR u9)

;; Protocol owner
(define-data-var contract-owner principal tx-sender)

;; Emergency pause switch
(define-data-var paused bool false)

;; Supported assets with configurations
(define-map supported-assets
  { asset-id: (string-ascii 32) }
  {
    token-contract: principal,
    price-feed-contract: principal,
    is-enabled: bool,
    borrow-enabled: bool,
    collateral-factor: uint,  ;; Value between 0-100, representing % of asset value usable as collateral
    borrow-cap: uint,        ;; Maximum amount that can be borrowed
    reserve-factor: uint     ;; Percentage of interest that goes to protocol reserves
  }
)

;; Asset market data
(define-map asset-markets
  { asset-id: (string-ascii 32) }
  {
    total-deposits: uint,
    total-borrows: uint,
    total-reserves: uint,
    supply-rate: uint,      ;; APY in basis points (e.g. 500 = 5%)
    borrow-rate: uint,      ;; APY in basis points
    last-update-block: uint,
    supply-index: uint,     ;; Cumulative index for interest accrual
    borrow-index: uint      ;; Cumulative index for interest accrual
  }
)

;; User deposits
(define-map user-deposits
  { user: principal, asset-id: (string-ascii 32) }
  {
    balance: uint,
    is-collateral: bool     ;; Whether this deposit is being used as collateral
  }
)

;; User borrows
(define-map user-borrows
  { user: principal, asset-id: (string-ascii 32) }
  {
    balance: uint,
    interest-index: uint    ;; Interest index at time of last update
  }
)

;; Risk parameters
(define-map risk-parameters
  { asset-id: (string-ascii 32) }
  {
    volatility-factor: uint,  ;; Higher for more volatile assets
    correlation-btc: int,     ;; Correlation with BTC (-100 to 100)
    max-ltv: uint,            ;; Maximum loan-to-value allowed
    liquidation-threshold: uint,  ;; Threshold that triggers liquidation
    liquidation-penalty: uint     ;; Penalty applied during liquidation
  }
)

;; Price cache to limit oracle calls
(define-map price-cache
  { asset-id: (string-ascii 32) }
  {
    price: uint,
    timestamp: uint,
    ttl: uint
  }
)

;; Check if caller is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; Check if protocol is paused
(define-private (is-paused)
  (var-get paused)
)

;; Update contract owner
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-contract-owner) (err ERR_UNAUTHORIZED))
    (ok (var-set contract-owner new-owner))
  )
)

;; Emergency pause/unpause the protocol
(define-public (set-paused (new-status bool))
  (begin
    (asserts! (is-contract-owner) (err ERR_UNAUTHORIZED))
    (ok (var-set paused new-status))
  )
)

;; Calculate interest accrual since last update
(define-private (calculate-interest-accrual (asset-id (string-ascii 32)) (time-elapsed uint))
  (let (
    (market (unwrap-panic (map-get? asset-markets { asset-id: asset-id })))
    (borrow-rate (get borrow-rate market))
    (total-borrows (get total-borrows market))
    (interest-factor (/ (* (* borrow-rate time-elapsed) u1) SECONDS_PER_YEAR))  ;; Annualized rate to actual rate
  )
    (/ (* total-borrows interest-factor) u10000)  ;; Scale back from basis points
  )
)

;; Calculate new index based on rate and time
(define-private (calculate-new-index (old-index uint) (rate uint) (time-elapsed uint))
  (let (
    (interest-factor (+ u10000 (/ (* (* rate time-elapsed) u1) SECONDS_PER_YEAR)))  ;; Annualized rate to actual rate
  )
    (/ (* old-index interest-factor) u10000)
  )
)

;; Update market data when a deposit occurs
(define-private (update-market-on-deposit (asset-id (string-ascii 32)) (amount uint))
  (let (
    (market (unwrap-panic (map-get? asset-markets { asset-id: asset-id })))
  )
    (map-set asset-markets
      { asset-id: asset-id }
      (merge market {
        total-deposits: (+ (get total-deposits market) amount)
      })
    )
  )
)

;; Update market data when a withdrawal occurs
(define-private (update-market-on-withdraw (asset-id (string-ascii 32)) (amount uint))
  (let (
    (market (unwrap-panic (map-get? asset-markets { asset-id: asset-id })))
  )
    (map-set asset-markets
      { asset-id: asset-id }
      (merge market {
        total-deposits: (- (get total-deposits market) amount)
      })
    )
  )
)

;; Update market data when a borrow occurs
(define-private (update-market-on-borrow (asset-id (string-ascii 32)) (amount uint))
  (let (
    (market (unwrap-panic (map-get? asset-markets { asset-id: asset-id })))
  )
    (map-set asset-markets
      { asset-id: asset-id }
      (merge market {
        total-borrows: (+ (get total-borrows market) amount)
      })
    )
  )
)

;; Get list of user collateral assets
(define-private (get-user-collateral-assets (user principal))

  (list 
    {asset-id: "STX", is-collateral: true}
    {asset-id: "BTC", is-collateral: false}
  )
)

;; Get list of user borrowed assets
(define-private (get-user-borrow-assets (user principal))

  (list "USDA" "STX")
)

;; Helper for market updates on repay
(define-private (update-market-on-repay (asset-id (string-ascii 32)) (amount uint))
  (let (
    (market (unwrap-panic (map-get? asset-markets {asset-id: asset-id})))
  )
    (map-set asset-markets
      {asset-id: asset-id}
      (merge market {
        total-borrows: (- (get total-borrows market) amount)
      })
    )
  )
)

;; Flash loan data structure to track outstanding loans
(define-map flash-loans
  {tx-hash: (buff 32)}
  {
    borrower: principal,
    asset-id: (string-ascii 32),
    amount: uint,
    fee: uint
  }
)

;; Verify flash loan repayment
(define-private (verify-flash-loan-repayment (tx-hash (buff 32)) (asset-id (string-ascii 32)) (amount uint) (fee uint))
  (let (
    (asset-config (unwrap-panic (map-get? supported-assets {asset-id: asset-id})))
    (token-contract (get token-contract asset-config))
    (protocol-address (as-contract tx-sender))
    (total-repayment (+ amount fee))
  )
    ;; Check if protocol balance increased by required amount
    ;; In a real implementation, this would need to track previous balance
    ;; This is a simplified placeholder that assumes balance check implementation
    (if true  ;; Placeholder for balance verification
      (begin
        (map-delete flash-loans {tx-hash: tx-hash})
        (ok true)
      )
      (err ERR_INSUFFICIENT_LIQUIDITY)
    )
  )
)

;; Calculate current utilization rate (scaled by 10000)
(define-private (calculate-utilization-rate (asset-id (string-ascii 32)))
  (let (
    (market (unwrap-panic (map-get? asset-markets {asset-id: asset-id})))
    (total-borrows (get total-borrows market))
    (total-deposits (get total-deposits market))
  )
    (if (is-eq total-deposits u0)
      u0
      (/ (* total-borrows u10000) total-deposits)
    )
  )
)

;; Calculate borrow interest rate based on utilization
(define-private (calculate-borrow-rate (asset-id (string-ascii 32)))
  (let (
    (utilization (calculate-utilization-rate asset-id))
  )
    (if (<= utilization OPTIMAL_UTILIZATION)
      ;; Below optimal: BASE_RATE + utilization * RATE_SLOPE_1 / optimal
      (+ BASE_RATE (/ (* utilization RATE_SLOPE_1) OPTIMAL_UTILIZATION))
      ;; Above optimal: BASE_RATE + RATE_SLOPE_1 + (utilization - optimal) * RATE_SLOPE_2 / (10000 - optimal)
      (+ (+ BASE_RATE RATE_SLOPE_1) 
         (/ (* (- utilization OPTIMAL_UTILIZATION) RATE_SLOPE_2) 
            (- u10000 OPTIMAL_UTILIZATION)))
    )
  )
)

;; Calculate supply interest rate based on utilization and borrow rate
(define-private (calculate-supply-rate (asset-id (string-ascii 32)))
  (let (
    (market (unwrap-panic (map-get? asset-markets {asset-id: asset-id})))
    (asset-config (unwrap-panic (map-get? supported-assets {asset-id: asset-id})))
    (utilization (calculate-utilization-rate asset-id))
    (borrow-rate (calculate-borrow-rate asset-id))
    (reserve-factor (get reserve-factor asset-config))
  )
    ;; supply-rate = borrow-rate * utilization * (1 - reserve-factor)
    (/ (* (* borrow-rate utilization) (- u100 reserve-factor)) u1000000)
  )
)

;; Enhanced Error Codes
(define-constant ERR_PAUSED u10)
(define-constant ERR_COLLATERAL_ALREADY_ENABLED u11)
(define-constant ERR_COLLATERAL_NOT_ENABLED u12)
(define-constant ERR_MAX_BORROWS_EXCEEDED u13)
(define-constant ERR_FLASH_LOAN_CALLBACK_FAILED u14)
(define-constant ERR_FLASH_LOAN_NOT_REPAID u15)
(define-constant ERR_GOVERNANCE_PROPOSAL_INACTIVE u16)
(define-constant ERR_GOVERNANCE_VOTE_ALREADY_CAST u17)
(define-constant ERR_REWARDS_CLAIM_FAILED u18)
(define-constant ERR_VAULT_STRATEGY_FAILED u19)
(define-constant ERR_ORACLE_STALE_PRICE u20)

;; Fee recipient
(define-data-var fee-recipient principal tx-sender)

;; User Health Factor Tracking
(define-map user-health
  { user: principal }
  {
    health-factor: uint,          ;; Current health factor (collateral value / loan value) * 100
    last-updated: uint,           ;; Timestamp of last update
    total-collateral-value: uint, ;; Total value of all collateral
    total-borrow-value: uint      ;; Total value of all borrows
  }
)


;;  Governance System
(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    description: (string-utf8 256),
    start-block: uint,
    end-block: uint,
    executed: bool,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 20), ;; "active", "passed", "failed", "executed"
    execution-payload: (optional (buff 1024))
  }
)

;;  User Governance Votes
(define-map governance-votes
  { user: principal, proposal-id: uint }
  {
    amount: uint,
    support: bool
  }
)

;; Reward Distribution System
(define-map reward-distribution
  { asset-id: (string-ascii 32) }
  {
    reward-token: principal,
    emission-rate: uint,      ;; Tokens per block
    reward-index: uint,       ;; Global index for reward accrual
    last-update-block: uint
  }
)

;; User Reward Claims
(define-map user-rewards
  { user: principal, reward-token: principal }
  {
    accrued: uint,
    claimed: uint
  }
)

;; User Liquidation Preferences
(define-map user-liquidation-preferences
  { user: principal }
  {
    self-liquidation-enabled: bool,   ;; Allow auto-liquidation to maintain health
    preferred-repay-asset: (optional (string-ascii 32)),
    preferred-collateral-priority: (list 5 (string-ascii 32)),
    notification-threshold: uint      ;; Health factor threshold for notifications
  }
)

;; 14. Yield Strategies
(define-map yield-strategies
  { asset-id: (string-ascii 32) }
  {
    strategy-contract: principal,
    allocation-percentage: uint,  ;; % of reserves allocated to this strategy
    active: bool,
    performance-fee: uint,        ;; Fee taken from yield generated
    last-harvest: uint            ;; Last time yield was collected
  }
)
