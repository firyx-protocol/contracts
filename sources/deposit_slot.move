// module fered::deposit_slot {
//     use std::signer;
//     use aptos_framework::object::{Self, Object};
//     use aptos_framework::timestamp;
//     use aptos_framework::coin::{Self, Coin};
//     use aptos_framework::event;
//     use aptos_framework::math64;
//     use fered::loan_position;

//     // === CONSTANTS ===
//     const PRECISION: u128 = 1000000;
//     const BASIS_POINTS: u64 = 10000;

//     // === ERRORS (existing + new) ===
//     const E_DEPOSIT_SLOT_NOT_FOUND: u64 = 4001;
//     const E_UNAUTHORIZED: u64 = 4002;
//     const E_INSUFFICIENT_BALANCE: u64 = 4003;
//     const E_INVALID_AMOUNT: u64 = 4004;
//     const E_POSITION_INACTIVE: u64 = 4005;
//     const E_INSUFFICIENT_LIQUIDITY: u64 = 4006;

//     // === STRUCTS (base unchanged) ===
//     struct DepositSlotInfo has key {
//         loan_position_addr: address,
//         lender: address,
//         principal: u64,
//         shares: u64,
//         debt_idx_at_deposit: u128,
//         created_at: u64,
//         active: bool,
//         total_yield_claimed: u64,
//         last_yield_claim: u64
//     }

//     struct GlobalState has key {
//         total_deposits: u64
//     }

//     // === EVENTS ===
//     #[event]
//     struct DepositAdded has drop, store {
//         deposit_slot: address,
//         lender: address,
//         amount: u64,
//         new_shares: u64
//     }

//     #[event]
//     struct LiquidityWithdrawn has drop, store {
//         deposit_slot: address,
//         lender: address,
//         amount: u64,
//         shares_burned: u64
//     }

//     #[event]
//     struct YieldClaimed has drop, store {
//         deposit_slot: address,
//         lender: address,
//         yield_amount: u64
//     }

//     // === INIT (unchanged) ===
//     fun init_module(deployer: &signer) {
//         move_to(deployer, GlobalState { total_deposits: 0 });
//     }

//     // === BASE CREATION (unchanged interface) ===
//     public(friend) fun create_deposit_slot(
//         lender: &signer,
//         loan_position_addr: address,
//         principal: u64,
//         shares: u64,
//         debt_idx_at_deposit: u128
//     ): Object<DepositSlotInfo> acquires GlobalState {
//         let state = borrow_global_mut<GlobalState>(@fered);
//         let lender_addr = signer::address_of(lender);
//         let constructor_ref = object::create_object(lender_addr);
//         let container_signer = object::generate_signer(&constructor_ref);

//         let deposit_info = DepositSlotInfo {
//             loan_position_addr,
//             lender: lender_addr,
//             principal,
//             shares,
//             debt_idx_at_deposit,
//             created_at: timestamp::now_seconds(),
//             active: true,
//             total_yield_claimed: 0,
//             last_yield_claim: timestamp::now_seconds()
//         };

//         move_to(&container_signer, deposit_info);
//         state.total_deposits += 1;

//         let deposit_obj =
//             object::object_from_constructor_ref<DepositSlotInfo>(&constructor_ref);
//         object::transfer(lender, deposit_obj, lender_addr);
//         deposit_obj
//     }

//     // === ENHANCED LIQUIDITY FUNCTIONS ===

//     /// Add more liquidity to existing deposit slot
//     public fun deposit_liquidity<Token>(
//         lender: &signer, deposit_slot: Object<DepositSlotInfo>, token: Coin<Token>
//     ) acquires DepositSlotInfo {
//         let slot_addr = object::object_address(&deposit_slot);
//         let deposit_info = borrow_global_mut<DepositSlotInfo>(slot_addr);
//         let amount = coin::value(&token);

//         assert!(deposit_info.lender == signer::address_of(lender), E_UNAUTHORIZED);
//         assert!(deposit_info.active, E_POSITION_INACTIVE);
//         assert!(amount > 0, E_INVALID_AMOUNT);

//         // Get current share price from loan position
//         let loan_position =
//             loan_position::lending_position(deposit_info.loan_position_addr);
//         let new_shares = calculate_shares_for_deposit(loan_position, amount);

//         // Update deposit info
//         deposit_info.principal += amount;
//         deposit_info.shares += new_shares;

//         // Add liquidity to underlying position
//         loan_position::deposit_liquidity(loan_position, amount as u128);

//         // Store token (simplified)
//         coin::destroy_zero(token);

//         event::emit(
//             DepositAdded {
//                 deposit_slot: slot_addr,
//                 lender: signer::address_of(lender),
//                 amount,
//                 new_shares
//             }
//         );
//     }

//     /// Withdraw liquidity from deposit slot
//     public fun withdraw_liquidity<Token>(
//         lender: &signer, deposit_slot: Object<DepositSlotInfo>, shares_to_burn: u64
//     ): Coin<Token> acquires DepositSlotInfo {
//         let slot_addr = object::object_address(&deposit_slot);
//         let deposit_info = borrow_global_mut<DepositSlotInfo>(slot_addr);

//         assert!(deposit_info.lender == signer::address_of(lender), E_UNAUTHORIZED);
//         assert!(deposit_info.active, E_POSITION_INACTIVE);
//         assert!(shares_to_burn <= deposit_info.shares, E_INSUFFICIENT_BALANCE);
//         assert!(shares_to_burn > 0, E_INVALID_AMOUNT);

//         // Calculate amount to withdraw based on current share price
//         let loan_position =
//             loan_position::lending_position(deposit_info.loan_position_addr);
//         let amount_to_withdraw =
//             calculate_withdrawal_amount(loan_position, shares_to_burn);

//         // Update deposit info
//         deposit_info.shares = deposit_info.shares - shares_to_burn;
//         deposit_info.principal =
//             if (deposit_info.principal > amount_to_withdraw) {
//                 deposit_info.principal - amount_to_withdraw
//             } else { 0 };

//         // If all shares withdrawn, mark as inactive
//         if (deposit_info.shares == 0) {
//             deposit_info.active = false;
//         };

//         event::emit(
//             LiquidityWithdrawn {
//                 deposit_slot: slot_addr,
//                 lender: signer::address_of(lender),
//                 amount: amount_to_withdraw,
//                 shares_burned: shares_to_burn
//             }
//         );

//         // Return token (simplified)
//         coin::zero<Token>()
//     }

//     /// Claim accumulated yield
//     public fun claim_yield<Token>(
//         lender: &signer, deposit_slot: Object<DepositSlotInfo>
//     ): Coin<Token> acquires DepositSlotInfo {
//         let slot_addr = object::object_address(&deposit_slot);
//         let deposit_info = borrow_global_mut<DepositSlotInfo>(slot_addr);

//         assert!(deposit_info.lender == signer::address_of(lender), E_UNAUTHORIZED);
//         assert!(deposit_info.active, E_POSITION_INACTIVE);

//         // Calculate claimable yield
//         let loan_position =
//             loan_position::lending_position(deposit_info.loan_position_addr);
//         let claimable_yield = calculate_claimable_yield(deposit_info, loan_position);

//         assert!(claimable_yield > 0, E_INSUFFICIENT_BALANCE);

//         // Update yield tracking
//         deposit_info.total_yield_claimed =
//             deposit_info.total_yield_claimed + claimable_yield;
//         deposit_info.last_yield_claim = timestamp::now_seconds();

//         // Claim from loan position
//         loan_position::claim_lender_yield(loan_position, deposit_info.lender);

//         event::emit(
//             YieldClaimed {
//                 deposit_slot: slot_addr,
//                 lender: signer::address_of(lender),
//                 yield_amount: claimable_yield
//             }
//         );

//         // Return yield tokens
//         coin::zero<Token>()
//     }

//     /// Emergency withdraw (with penalty)
//     public fun emergency_withdraw<Token>(
//         lender: &signer, deposit_slot: Object<DepositSlotInfo>
//     ): Coin<Token> acquires DepositSlotInfo {
//         let slot_addr = object::object_address(&deposit_slot);
//         let deposit_info = borrow_global_mut<DepositSlotInfo>(slot_addr);

//         assert!(deposit_info.lender == signer::address_of(lender), E_UNAUTHORIZED);
//         assert!(deposit_info.active, E_POSITION_INACTIVE);

//         // Apply emergency withdrawal penalty (5%)
//         let penalty_rate = 500; // 5%
//         let gross_amount = deposit_info.principal;
//         let penalty = (gross_amount * penalty_rate) / BASIS_POINTS;
//         let net_amount = gross_amount - penalty;

//         // Mark as inactive
//         deposit_info.active = false;
//         deposit_info.shares = 0;

//         // Return net amount
//         coin::zero<Token>()
//     }

//     // === CALCULATION FUNCTIONS ===

//     fun calculate_shares_for_deposit(
//         loan_position: Object<loan_position::LoanPosition>, amount: u64
//     ): u64 {
//         // Get share price from loan position
//         let shares =
//             loan_position::calculate_shares_for_amount(loan_position, amount as u128);
//         shares as u64
//     }

//     fun calculate_withdrawal_amount(
//         loan_position: Object<loan_position::LoanPosition>, shares: u64
//     ): u64 {
//         // Calculate withdrawal amount based on current share price
//         let (liquidity, _, _, _) = loan_position::get_position_info(loan_position);
//         let (_, _, debt_index) = loan_position::get_interest_rates(loan_position);

//         // Simplified calculation
//         (shares * (liquidity as u64)) / 1000000 // Would use proper share price
//     }

//     fun calculate_claimable_yield(
//         deposit_info: &DepositSlotInfo, loan_position: Object<loan_position::LoanPosition>
//     ): u64 {
//         // Calculate yield based on shares and time elapsed
//         let (_, pending_yields, yield_per_share) =
//             loan_position::get_yield_info(loan_position);
//         let total_entitled = ((deposit_info.shares as u128) * yield_per_share) / PRECISION;
//         let claimable = total_entitled - (deposit_info.total_yield_claimed as u128);

//         math64::min(claimable as u64, pending_yields as u64)
//     }

//     // === VIEW FUNCTIONS ===

//     #[view]
//     public fun get_deposit_info(
//         deposit_slot: Object<DepositSlotInfo>
//     ): (address, u64, u64, bool) acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         (
//             deposit_info.lender,
//             deposit_info.principal,
//             deposit_info.shares,
//             deposit_info.active
//         )
//     }

//     #[view]
//     public fun get_extended_info(
//         deposit_slot: Object<DepositSlotInfo>
//     ): (u64, u64, u64, u128) acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         (
//             deposit_info.created_at,
//             deposit_info.total_yield_claimed,
//             deposit_info.last_yield_claim,
//             deposit_info.debt_idx_at_deposit
//         )
//     }

//     #[view]
//     public fun calculate_current_value(
//         deposit_slot: Object<DepositSlotInfo>
//     ): (u64, u64) acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         let loan_position =
//             loan_position::lending_position(deposit_info.loan_position_addr);

//         let current_value =
//             calculate_withdrawal_amount(loan_position, deposit_info.shares);
//         let claimable_yield = calculate_claimable_yield(deposit_info, loan_position);

//         (current_value, claimable_yield)
//     }

//     #[view]
//     public fun get_position_summary(
//         deposit_slot: Object<DepositSlotInfo>
//     ): (address, u64, u64, u64, bool) acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         let loan_position =
//             loan_position::lending_position(deposit_info.loan_position_addr);
//         let (current_value, claimable_yield) = calculate_current_value(deposit_slot);

//         (
//             deposit_info.loan_position_addr,
//             current_value,
//             claimable_yield,
//             deposit_info.shares,
//             deposit_info.active
//         )
//     }

//     // === HELPER FUNCTIONS ===

//     inline fun borrow_deposit_slot(object: Object<DepositSlotInfo>): &DepositSlotInfo {
//         let addr = object::object_address(&object);
//         assert!(object::object_exists<DepositSlotInfo>(addr), E_DEPOSIT_SLOT_NOT_FOUND);
//         borrow_global<DepositSlotInfo>(addr)
//     }

//     public fun is_deposit_active(
//         deposit_slot: Object<DepositSlotInfo>
//     ): bool acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         deposit_info.active
//     }

//     public fun get_lender_address(
//         deposit_slot: Object<DepositSlotInfo>
//     ): address acquires DepositSlotInfo {
//         let deposit_info =
//             borrow_global<DepositSlotInfo>(object::object_address(&deposit_slot));
//         deposit_info.lender
//     }
// }

