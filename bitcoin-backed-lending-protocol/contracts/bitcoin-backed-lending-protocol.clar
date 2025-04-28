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

