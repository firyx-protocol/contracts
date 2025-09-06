// module fered::loan_slot {
//     use std::signer;
//     use aptos_framework::account::{Self, SignerCapability};
//     use aptos_framework::fungible_asset::{Metadata};
//     use aptos_framework::object::{Self, Object};
//     use aptos_framework::timestamp;
//     use aptos_framework::event;
//     use aptos_framework::math128;
//     use aptos_framework::table::{Self, Table};
//     use dex_contract::position_v3::Info;
//     use dex_contract::router_v3;

//     use fered::math::{bps};

//     // === CONSTANTS ===
//     const PRECISION: u128 = 1_000_000;
//     const SECONDS_PER_YEAR: u64 = 31536000;

//     // === ERRORS ===
//     const E_LOAN_SLOT_NOT_FOUND: u64 = 2001;
//     const E_INSUFFICIENT_LIQUIDITY: u64 = 2002;
//     const E_INVALID_UTILIZATION: u64 = 2003;
//     const E_BORROW_CAPACITY_EXCEEDED: u64 = 2004;
//     const E_UNAUTHORIZED: u64 = 2005;
//     const E_BORROW_NOT_FOUND: u64 = 2006;
//     const E_INSUFFICIENT_COLLATERAL: u64 = 2007;
//     const E_PAYMENT_OVERDUE: u64 = 2008;
//     const E_INSUFFICIENT_BORROWED_BALANCE: u64 = 2009;

//     // === STRUCTS ===
//     struct Params has copy, drop, store {
//         ltv: u64, // loan-to-value ratio in BPS
//         slope_before_kink: u64, // utilization slope before kink in BPS
//         slope_after_kink: u64, // utilization slope after kink in BPS
//         kink_util: u64, // utilization at which slope changes (in BPS)
//         risk_factor: u64 // risk factor in BPS
//     }

//     struct Cap has drop, store {
//         signer_cap: SignerCapability
//     }

//     struct LoanSlot has key {
//         lp: Object<Info>,
//         total_liq: u128, // Total liquidity from all lenders
//         util: u64, // in BPS
//         avail_borrow: u64,
//         total_borrow: u64,
//         params: Params,
//         cap: Cap,

//         // Extended fields for multi-lender support
//         owner: address, // Position creator (for initial setup)
//         created_ts: u64,
//         last_yield_ts: u64,

//         // Yield tracking per share (for FLT token holders)
//         yield_per_share: u128, // Total accumulated yield per FLT token
//         amm_yield_per_share: u128, // AMM farming yield per FLT token
//         interest_per_share: u128, // Interest income per FLT token
//         debt_idx: u128, // Current debt index (starts at PRECISION)
//         last_idx_update: u64,

//         // Borrow tracking
//         borrows: Table<u64, BorrowInfo>, // borrow_id -> BorrowInfo
//         next_bid: u64,

//         // Multi-lender tracking
//         flt_supply: u128, // Total FLT tokens minted for this position
//         num_lenders: u64, // Number of unique lenders

//         // Protocol fees
//         protocol_fees: u128,

//         // Asset pools for borrowed assets
//         borrowed_assets: Table<address, u64>, // token_address -> amount
//         collateral_pool: Table<address, u64> // token_address -> amount
//     }

//     struct BorrowInfo has store, copy, drop {
//         borrower: address,
//         principal: u64,
//         coll: u64,
//         debt_idx_at_borrow: u128,
//         ts: u64,
//         active: bool,
//         withdrawn_amount: u64,
//         last_payment: u64,
//         collateral_token: address
//     }

//     struct ProtocolState has key {
//         admin_cap: SignerCapability,
//         tvl: u128,
//         total_slots: u64
//     }


//     /// Create a new Position and return the object handle
//     public fun create_loan_slot(
//         owner: address,
//         lp: Object<Info>,
//         signer_cap: SignerCapability,
//         ltv: u64,
//         slope_before_kink: u64,
//         slope_after_kink: u64,
//         kink_util: u64,
//         risk_factor: u64
//     ): Object<LoanSlot> {
//         let constructor_ref = object::create_object(object::object_address(&lp));
//         let pos_obj = object::object_from_constructor_ref<LoanSlot>(&constructor_ref);
//         let obj_signer = object::generate_signer(&constructor_ref);

//         move_to(
//             &obj_signer,
//             LoanSlot {
//                 lp,
//                 total_liq: 0,
//                 util: 0,
//                 avail_borrow: 0,
//                 total_borrow: 0,
//                 params: Params {
//                     ltv,
//                     slope_before_kink,
//                     slope_after_kink,
//                     kink_util,
//                     risk_factor
//                 },
//                 cap: Cap { signer_cap },

//                 // Initialize extended fields for multi-lender support
//                 owner,
//                 created_ts: timestamp::now_seconds(),
//                 last_yield_ts: timestamp::now_seconds(),
//                 yield_per_share: 0,
//                 amm_yield_per_share: 0,
//                 interest_per_share: 0,
//                 debt_idx: PRECISION, // Start at 1.0
//                 last_idx_update: timestamp::now_seconds(),
//                 borrows: table::new(),
//                 next_bid: 1,
//                 flt_supply: 0,
//                 num_lenders: 0,
//                 protocol_fees: 0
//             }
//         );

//         pos_obj
//     }

//     // === MULTI-LENDER FUNCTIONS ===

//     /// Add liquidity to position - returns FLT tokens to be minted
//     public fun deposit(
//         slot: Object<LoanSlot>, lender: address, amount: u64
//     ): u128 acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&slot);
//         let pos = borrow_global_mut<LoanSlot>(loan_slot_addr);

//         // Calculate FLT tokens to mint
//         let flt_to_mint =
//             if (pos.flt_supply == 0) {
//                 (amount as u128)
//             } else {
//                 math128::mul_div(amount as u128, pos.flt_supply, pos.total_liq)
//             };

//         // Update position state
//         pos.total_liq +=(amount as u128);
//         pos.flt_supply += flt_to_mint;

//         // Update available borrow capacity
//         let new_available =
//             math128::mul_div(pos.total_liq, pos.params.ltv as u128, bps() as u128);
//         pos.avail_borrow = (new_available as u64) - pos.total_borrow;

//         // Update lender count (simplified - should track unique lenders properly)
//         pos.num_lenders += 1;

//         event::emit(
//             LiquidityAdded {
//                 position: loan_slot_addr,
//                 lender,
//                 amount,
//                 flt_minted: flt_to_mint,
//                 new_total_liquidity: pos.total_liq
//             }
//         );

//         flt_to_mint
//     }

//     /// Remove liquidity from position - burns FLT tokens
//     public fun withdraw(
//         loan_slot: Object<LoanSlot>,
//         lender: address,
//         flt_amount: u128,
//         slippage_numerators: u256,
//         slippage_denominator: u256
//     ) acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&loan_slot);
//         let loan_slot = borrow_global_mut<LoanSlot>(loan_slot_addr);

//         let amount = withdraw_internal(loan_slot, flt_amount);

//         let obj_signer =
//             account::create_signer_with_capability(&loan_slot.cap.signer_cap);

//         router_v3::remove_liquidity_single(
//             &obj_signer,
//             loan_slot.lp,
//             amount as u128,
//             object::address_to_object<Metadata>(@usdc),
//             slippage_numerators,
//             slippage_denominator
//         );

//         event::emit(
//             LiquidityRemoved {
//                 position: loan_slot_addr,
//                 lender,
//                 amount,
//                 flt_burned: flt_amount,
//                 remaining_liquidity: loan_slot.total_liq
//             }
//         );
//     }

//     fun withdraw_internal(loan_slot: &mut LoanSlot, flt_amount: u128): u128 {
//         assert!(flt_amount <= loan_slot.flt_supply, E_INSUFFICIENT_LIQUIDITY);

//         let liquidity_to_return =
//             calc_liquidity_for_flt(
//                 flt_amount, loan_slot.total_liq, loan_slot.flt_supply
//             );
//         let remaining_liquidity = loan_slot.total_liq - liquidity_to_return;
//         let max_borrow_capacity =
//             calc_max_borrow_capacity(remaining_liquidity, loan_slot.params.ltv);

//         // Update position state
//         loan_slot.total_liq = remaining_liquidity;
//         loan_slot.flt_supply -= flt_amount;
//         loan_slot.avail_borrow = (max_borrow_capacity as u64) - loan_slot.total_borrow;
//         loan_slot.num_lenders -= 1;

//         liquidity_to_return
//     }

//     fun assert_borrow_capacity_ok(
//         total_borrow: u64, max_borrow_capacity: u128
//     ) {
//         assert!((total_borrow as u128) <= max_borrow_capacity, E_BORROW_CAPACITY_EXCEEDED);
//     }

//     fun calc_max_borrow_capacity(remaining_liq: u128, ltv: u64): u128 {
//         math128::mul_div(remaining_liq, ltv as u128, bps() as u128)
//     }

//     fun calc_liquidity_for_flt(
//         flt_amount: u128, total_liq: u128, flt_supply: u128
//     ): u128 {
//         math128::mul_div(flt_amount, total_liq, flt_supply)
//     }

//     // === BORROWING FUNCTIONS ===

//     /// Execute borrow against position
//     public fun borrow(
//         loan_slot_obj: Object<LoanSlot>,
//         borrower: address,
//         borrow_amount: u64,
//         coll_amount: u64
//     ): u64 acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&loan_slot_obj);
//         let loan_slot = borrow_global_mut<LoanSlot>(loan_slot_addr);

//         // Validate borrow amount & collateral
//         assert_can_borrow(
//             loan_slot.avail_borrow,
//             borrow_amount,
//             coll_amount,
//             loan_slot.total_liq
//         );

//         // Update debt index before new borrow
//         accrue_interest(loan_slot_obj);

//         // Create borrow record
//         let bid = loan_slot.next_bid;
//         let current_time = timestamp::now_seconds();

//         let borrow_info = BorrowInfo {
//             borrower,
//             principal: borrow_amount,
//             coll: coll_amount,
//             debt_idx_at_borrow: loan_slot.debt_idx,
//             ts: current_time,
//             active: true
//         };

//         loan_slot.borrows.add(bid, borrow_info);

//         loan_slot.next_bid = bid + 1;
//         loan_slot.total_borrow += borrow_amount;
//         loan_slot.avail_borrow -= borrow_amount;
//         loan_slot.util =
//             math128::mul_div(
//                 loan_slot.total_borrow as u128,
//                 bps() as u128,
//                 loan_slot.total_liq
//             ) as u64;

//         event::emit(
//             BorrowExecuted {
//                 position: loan_slot_addr,
//                 borrow_id: bid,
//                 borrower,
//                 amount: borrow_amount,
//                 collateral: coll_amount
//             }
//         );

//         bid
//     }

//     fun calculate_required_collateral(
//         borrow_amount: u64, total_liq: u128
//     ): u64 {
//         math128::mul_div(
//             borrow_amount as u128,
//             (borrow_amount as u128) * (bps() as u128) / total_liq,
//             (bps() as u128) - ((borrow_amount as u128) * (bps() as u128) / total_liq)
//         ) as u64
//     }

//     fun assert_can_borrow(
//         avail_borrow: u64,
//         borrow_amount: u64,
//         coll_amount: u64,
//         total_liq: u128
//     ) {
//         assert!(borrow_amount <= avail_borrow, E_BORROW_CAPACITY_EXCEEDED);
//         let required_coll = calculate_required_collateral(borrow_amount, total_liq);
//         assert!(coll_amount >= required_coll, E_INSUFFICIENT_LIQUIDITY);
//     }

//     // === YIELD MANAGEMENT ===

//     /// Collect yields from AMM farming and distribute to FLT holders
//     public fun claim_yield(position: Object<LoanSlot>) acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&position);
//         let pos = borrow_global_mut<LoanSlot>(loan_slot_addr);

//         let protocol_signer = account::create_signer_with_capability(&pos.cap.signer_cap);

//         // Collect fees from Hyperion LP
//         router_v3::claim_fees(
//             &protocol_signer,
//             vector[object::object_address(&pos.lp)],
//             signer::address_of(&protocol_signer)
//         );

//         // TODO: Get actual yield amount from DEX response
//         let yield_amount = 1000; // Placeholder

//         // Calculate yield per share for FLT holders
//         let yield_per_share =
//             if (pos.flt_supply > 0) {
//                 (yield_amount as u128) * PRECISION / pos.flt_supply
//             } else { 0 };

//         pos.amm_yield_per_share += yield_per_share;
//         pos.yield_per_share += yield_per_share;
//         pos.last_yield_ts = timestamp::now_seconds();

//         event::emit(
//             YieldCollected {
//                 position: loan_slot_addr,
//                 amount: (yield_amount as u128),
//                 yield_type: 1, // AMM yields
//                 yield_per_share
//             }
//         );
//     }

//     /// Update debt index and distribute interest to FLT holders
//     public fun accrue_interest(position: Object<LoanSlot>) acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&position);
//         let pos = borrow_global_mut<LoanSlot>(loan_slot_addr);

//         let current_time = timestamp::now_seconds();
//         let time_elapsed = current_time - pos.last_idx_update;

//         if (time_elapsed == 0) return;

//         // Calculate current interest rate
//         let current_rate =
//             get_borrow_rate(
//                 pos.util,
//                 pos.params.slope_before_kink,
//                 pos.params.slope_after_kink,
//                 pos.params.kink_util
//             );

//         // Update debt index: index = index * (1 + rate * time/year)
//         let old_index = pos.debt_idx;
//         let rate_factor =
//             PRECISION
//                 + (current_rate as u128) * (time_elapsed as u128)
//                     / (SECONDS_PER_YEAR as u128);
//         pos.debt_idx = pos.debt_idx * rate_factor / PRECISION;
//         pos.last_idx_update = current_time;

//         // Calculate interest accrued and distribute to FLT holders
//         let interest_accrued =
//             if (pos.debt_idx > old_index) {
//                 (pos.total_borrow as u128) * (pos.debt_idx - old_index) / PRECISION
//             } else { 0 };

//         if (interest_accrued > 0 && pos.flt_supply > 0) {
//             let interest_per_share = interest_accrued * PRECISION / pos.flt_supply;
//             pos.interest_per_share += interest_per_share;
//             pos.yield_per_share += interest_per_share;

//             event::emit(
//                 DebtIndexUpdated {
//                     position: loan_slot_addr,
//                     old_index,
//                     new_index: pos.debt_idx,
//                     interest_accrued
//                 }
//             );
//         };
//     }

//     /// Calculate current borrow interest rate
//     public fun get_borrow_rate(
//         util: u64,
//         slope_before_kink: u64,
//         slope_after_kink: u64,
//         kink_util: u64
//     ): u64 {
//         let base_rate = 100; // 1% base rate

//         if (util <= kink_util) {
//             // Before kink: base + slope_before * utilization
//             base_rate + (slope_before_kink * util) / bps()
//         } else {
//             // After kink: base + slope_before + slope_after * excess_utilization
//             let excess_util = util - kink_util;
//             let excess_rate = (slope_after_kink * excess_util) / (bps() - kink_util);
//             base_rate + slope_before_kink + excess_rate
//         }
//     }

//     // === VIEW FUNCTIONS ===

//     #[view]
//     public fun position(loan_slot_addr: address): Object<LoanSlot> {
//         object::address_to_object<LoanSlot>(loan_slot_addr)
//     }

//     #[view]
//     public fun get_position_info(
//         position: Object<LoanSlot>
//     ): (
//         u128, // total_liq
//         u64, // util
//         u64, // avail_borrow
//         u64, // total_borrow
//         u128, // debt_idx
//         u128, // flt_supply
//         u128 // yield_per_share
//     ) acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&position);
//         if (!exists<LoanSlot>(loan_slot_addr)) {
//             return (0, 0, 0, 0, PRECISION, 0, 0)
//         };

//         let pos = borrow_global<LoanSlot>(loan_slot_addr);
//         (
//             pos.total_liq,
//             pos.util,
//             pos.avail_borrow,
//             pos.total_borrow,
//             pos.debt_idx,
//             pos.flt_supply,
//             pos.yield_per_share
//         )
//     }

//     #[view]
//     public fun claimable_yield(
//         position: Object<LoanSlot>, flt_balance: u128
//     ): u128 acquires LoanSlot {
//         let loan_slot_addr = object::object_address(&position);
//         if (!exists<LoanSlot>(loan_slot_addr)) {
//             return 0
//         };

//         let pos = borrow_global<LoanSlot>(loan_slot_addr);
//         // Calculate claimable yield based on FLT balance and accumulated yield per share
//         math128::mul_div(flt_balance, pos.yield_per_share, PRECISION)
//     }
// }

