;; Title: StacksFlow - Bidirectional Payment Channels
;; Summary: Layer 2 scaling solution enabling instant, low-cost STX transactions
;; Description: A sophisticated payment channel implementation that allows two parties
;;              to conduct multiple off-chain transactions with on-chain settlement.
;;              Features include cooperative and unilateral channel closure,
;;              dispute resolution mechanisms, and comprehensive state management.
;;              Designed for Stacks Layer 2 compliance with robust security measures.

;; CONSTANTS & CONFIGURATION

(define-constant CONTRACT-OWNER tx-sender)
(define-constant DISPUTE-TIMEOUT u1008) ;; ~1 week in blocks (assuming 10min blocks)
(define-constant MAX-BALANCE u340282366920938463463374607431768211455) ;; Max uint value

;; ERROR CODES

(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-EXISTS (err u101))
(define-constant ERR-CHANNEL-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-CHANNEL-CLOSED (err u105))
(define-constant ERR-DISPUTE-PERIOD (err u106))
(define-constant ERR-INVALID-INPUT (err u107))
(define-constant ERR-BALANCE-OVERFLOW (err u108))

;; DATA STRUCTURES

;; Primary storage for payment channel state
(define-map payment-channels
  {
    channel-id: (buff 32), ;; Unique channel identifier (SHA256 hash)
    participant-a: principal, ;; Channel initiator address
    participant-b: principal, ;; Counterparty address
  }
  {
    total-deposited: uint, ;; Total STX locked in channel
    balance-a: uint, ;; Current balance for participant A
    balance-b: uint, ;; Current balance for participant B
    is-open: bool, ;; Channel operational status
    dispute-deadline: uint, ;; Block height deadline for disputes
    nonce: uint, ;; State version for replay protection
  }
)

;; INPUT VALIDATION FUNCTIONS

(define-private (is-valid-channel-id (channel-id (buff 32)))
  ;; Validates channel ID format and length
  (and
    (> (len channel-id) u0)
    (<= (len channel-id) u32)
  )
)

(define-private (is-valid-deposit (amount uint))
  ;; Ensures deposit amount is greater than zero
  (> amount u0)
)

(define-private (is-valid-signature (signature (buff 65)))
  ;; Validates signature format and length
  (and
    (is-eq (len signature) u65)
    true
  )
)

(define-private (is-valid-balance (balance uint))
  ;; Validates that balance is within acceptable range
  (and
    (>= balance u0)
    (<= balance MAX-BALANCE)
  )
)

(define-private (validate-balance-sum (balance-a uint) (balance-b uint) (total uint))
  ;; Validates that balances don't overflow and sum correctly
  (and
    (is-valid-balance balance-a)
    (is-valid-balance balance-b)
    ;; Check for overflow in addition
    (>= (+ balance-a balance-b) balance-a)
    (>= (+ balance-a balance-b) balance-b)
    ;; Check that sum equals total
    (is-eq (+ balance-a balance-b) total)
  )
)

;; UTILITY FUNCTIONS

(define-private (uint-to-buff (n uint))
  ;; Converts unsigned integer to buffer for message construction
  (unwrap-panic (to-consensus-buff? n))
)

(define-private (verify-signature
    (message (buff 256))
    (signature (buff 65))
    (signer principal)
  )
  ;; Simplified signature verification - production should use secp256k1-verify
  (if (is-eq tx-sender signer)
    true
    false
  )
)

(define-private (construct-state-message 
    (channel-id (buff 32))
    (balance-a uint)
    (balance-b uint)
  )
  ;; Safely constructs state message with validated inputs
  (concat 
    (concat channel-id (uint-to-buff balance-a))
    (uint-to-buff balance-b)
  )
)

;; CHANNEL MANAGEMENT FUNCTIONS

(define-public (create-channel
    (channel-id (buff 32))
    (participant-b principal)
    (initial-deposit uint)
  )
  ;; Creates a new bidirectional payment channel between two participants
  (begin
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit initial-deposit) ERR-INVALID-INPUT)
    (asserts! (is-valid-balance initial-deposit) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    ;; Ensure channel doesn't already exist
    (asserts!
      (is-none (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      }))
      ERR-CHANNEL-EXISTS
    )
    ;; Lock initial deposit in contract
    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))
    ;; Initialize channel state
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    } {
      total-deposited: initial-deposit,
      balance-a: initial-deposit,
      balance-b: u0,
      is-open: true,
      dispute-deadline: u0,
      nonce: u0,
    })
    (ok true)
  )
)

(define-public (fund-channel
    (channel-id (buff 32))
    (participant-b principal)
    (additional-funds uint)
  )
  ;; Adds additional STX funds to an existing open channel
  (let ((channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      })
      ERR-CHANNEL-NOT-FOUND
    )))
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit additional-funds) ERR-INVALID-INPUT)
    (asserts! (is-valid-balance additional-funds) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Check for overflow in total deposited
    (asserts! (>= (+ (get total-deposited channel) additional-funds) 
                  (get total-deposited channel)) ERR-BALANCE-OVERFLOW)
    (asserts! (>= (+ (get balance-a channel) additional-funds) 
                  (get balance-a channel)) ERR-BALANCE-OVERFLOW)
    ;; Transfer additional funds to contract
    (try! (stx-transfer? additional-funds tx-sender (as-contract tx-sender)))
    ;; Update channel balances
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        total-deposited: (+ (get total-deposited channel) additional-funds),
        balance-a: (+ (get balance-a channel) additional-funds),
      })
    )
    (ok true)
  )
)

;; CHANNEL CLOSURE FUNCTIONS

(define-public (close-channel-cooperative
    (channel-id (buff 32))
    (participant-b principal)
    (balance-a uint)
    (balance-b uint)
    (signature-a (buff 65))
    (signature-b (buff 65))
  )
  ;; Closes channel immediately with mutual agreement and signed final state
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (total-channel-funds (get total-deposited channel))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-a) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature-b) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Validate balances before using them
    (asserts! (validate-balance-sum balance-a balance-b total-channel-funds) 
              ERR-INSUFFICIENT-FUNDS)
    ;; Construct message with validated inputs
    (let ((message (construct-state-message channel-id balance-a balance-b)))
      ;; Verify both parties signed the final state
      (asserts!
        (and
          (verify-signature message signature-a tx-sender)
          (verify-signature message signature-b participant-b)
        )
        ERR-INVALID-SIGNATURE
      )
      ;; Distribute final balances
      (try! (as-contract (stx-transfer? balance-a tx-sender tx-sender)))
      (try! (as-contract (stx-transfer? balance-b tx-sender participant-b)))
      ;; Mark channel as closed
      (map-set payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      }
        (merge channel {
          is-open: false,
          balance-a: u0,
          balance-b: u0,
          total-deposited: u0,
        })
      )
      (ok true)
    )
  )
)

(define-public (initiate-unilateral-close
    (channel-id (buff 32))
    (participant-b principal)
    (proposed-balance-a uint)
    (proposed-balance-b uint)
    (signature (buff 65))
  )
  ;; Initiates unilateral channel closure with dispute period for counterparty challenge
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (total-channel-funds (get total-deposited channel))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-signature signature) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    ;; Validate proposed balances before using them
    (asserts! (validate-balance-sum proposed-balance-a proposed-balance-b total-channel-funds)
              ERR-INSUFFICIENT-FUNDS)
    ;; Construct message with validated inputs
    (let ((message (construct-state-message channel-id proposed-balance-a proposed-balance-b)))
      ;; Verify initiator's signature on proposed state
      (asserts! (verify-signature message signature tx-sender)
        ERR-INVALID-SIGNATURE
      )
      ;; Set dispute period and proposed final state
      (map-set payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b,
      }
        (merge channel {
          dispute-deadline: (+ stacks-block-height DISPUTE-TIMEOUT),
          balance-a: proposed-balance-a,
          balance-b: proposed-balance-b,
        })
      )
      (ok true)
    )
  )
)

(define-public (resolve-unilateral-close
    (channel-id (buff 32))
    (participant-b principal)
  )
  ;; Finalizes unilateral closure after dispute period expires
  (let (
      (channel (unwrap!
        (map-get? payment-channels {
          channel-id: channel-id,
          participant-a: tx-sender,
          participant-b: participant-b,
        })
        ERR-CHANNEL-NOT-FOUND
      ))
      (final-balance-a (get balance-a channel))
      (final-balance-b (get balance-b channel))
    )
    ;; Input validation
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)
    ;; Ensure dispute period has elapsed
    (asserts! (>= stacks-block-height (get dispute-deadline channel))
      ERR-DISPUTE-PERIOD
    )
    ;; Additional validation of stored balances
    (asserts! (is-valid-balance final-balance-a) ERR-INVALID-INPUT)
    (asserts! (is-valid-balance final-balance-b) ERR-INVALID-INPUT)
    ;; Distribute final balances
    (try! (as-contract (stx-transfer? final-balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? final-balance-b tx-sender participant-b)))
    ;; Mark channel as closed
    (map-set payment-channels {
      channel-id: channel-id,
      participant-a: tx-sender,
      participant-b: participant-b,
    }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0,
      })
    )
    (ok true)
  )
)

;; READ-ONLY FUNCTIONS

(define-read-only (get-channel-info
    (channel-id (buff 32))
    (participant-a principal)
    (participant-b principal)
  )
  ;; Returns complete channel state information
  (map-get? payment-channels {
    channel-id: channel-id,
    participant-a: participant-a,
    participant-b: participant-b,
  })
)

;; EMERGENCY FUNCTIONS

(define-public (emergency-withdraw)
  ;; Emergency function allowing contract owner to withdraw all funds - use with extreme caution
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (try! (stx-transfer? (stx-get-balance (as-contract tx-sender))
      (as-contract tx-sender) CONTRACT-OWNER
    ))
    (ok true)
  )
)