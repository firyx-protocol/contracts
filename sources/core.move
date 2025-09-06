// module fered::core {
//     use std::option::{Self, Option};
//     use std::string::{Self, String};
//     use std::vector;
//     use std::signer;
//     use aptos_framework::timestamp;
//     use aptos_framework::coin::{Self, Coin};
//     use aptos_framework::fungible_asset::{Self, Metadata, MintRef, BurnRef, TransferRef};
//     use aptos_framework::dispatchable_fungible_asset;
//     use aptos_framework::account::{Self, SignerCapability};
//     use aptos_framework::object::{Self, Object};
//     use aptos_framework::hash;
//     use aptos_framework::bcs;
//     use dex_contract::pool_v3::{Self, LiquidityPoolV3};
//     use dex_contract::lp::{Self};
//     use dex_contract::router_v3::{Self};
//     use dex_contract::position_v3::{Self, Info};

//     use fered::math::{Self, bps};

//     // === ERRORS ===
//     const E_INSUFFICIENT_COLLATERAL: u64 = 1001;
//     const E_POSITION_NOT_FOUND: u64 = 1002;
//     const E_UNAUTHORIZED: u64 = 1003;
//     const E_INSUFFICIENT_FEE_PAYMENT: u64 = 1004;
//     const E_OVERDUE_PAYMENT: u64 = 1005;

//     // === CONSTANTS ===
//     const DURATION_NO_LIMIT: u64 = 0;

//     const BASE_RATE_BPS: u64 = 200; // 2%
//     const SLOPE_BEFORE_KINK_BPS: u64 = 400; // 4%
//     const SLOPE_AFTER_KINK_BPS: u64 = 2000; // 20%
//     const KINK_UTILIZATION_BPS: u64 = 8000; // 80%
//     const RISK_FACTOR_BPS: u64 = 1000; // 10%
//     const LTV_BPS: u64 = 5000; // 50%
//     const YIELD_FLOOR_BPS: u64 = 100; // 1%
//     const RISK_PREMIUM_BPS: u64 = 200; // 2%

//     // Struct for store signer of contract only
//     struct Admin has key {
//         signer_cap: SignerCapability
//     }
    
//     use fered::lending_position::{Self, LendingPosition, LendingPositionParameters, LendingPositionCap};

//     // struct LendingPositionStore has key {
//     //     positions: vector<LendingPosition>
//     // }

//     struct Controller has key {
//         lplt_usdc_addr: address,
//         lpbt_usdc_addr: address
//     }

//     fun init_module(admin: &signer) {
//         let (_, signer_cap) = account::create_resource_account(admin, b"ferred_admin");

//         move_to(admin, Admin { signer_cap });
//     }

//     public entry fun open_position(
//         lender: &signer,
//         token_a: Object<Metadata>,
//         token_b: Object<Metadata>,
//         fee_tier: u8, // index in [0, 1, 2, 3] in [100, 500, 3000, 10000]
//         tick_lower: u32,
//         tick_upper: u32,

//         // parameters
//         parameters_ltv: u64,
//         parameters_slope_before_kink: u64,
//         parameters_slope_after_kink: u64,
//         parameters_kink_utilization: u64,
//         parameters_risk_factor: u64,
//     ) acquires Admin {
//         let admin = borrow_global<Admin>(@admin);
//         let admin_signer = account::create_signer_with_capability(&admin.signer_cap);
//         let admin_adrr = @admin;

//         let constructor_ref = object::create_object(admin_adrr);
//         let object_signer = object::generate_signer(&constructor_ref);
        
//         let lp_object = pool_v3::open_position(
//             &object_signer,
//             token_a,
//             token_b,
//             fee_tier,
//             tick_lower,
//             tick_upper
//         );
        
//         let lending_position_object = lending_position::create_lending_position(
//             lp_object,
//             admin.signer_cap,
//             parameters_ltv,
//             parameters_slope_before_kink,
//             parameters_slope_after_kink,
//             parameters_kink_utilization,
//             parameters_risk_factor
//         );

//         object::transfer(
//             &admin_signer, lending_position_object, signer::address_of(&object_signer)
//         );
//     }

//     public entry fun close_position() {}

//     public entry fun calculate_borrower_apr() {}

//     public entry fun calculate_lender_apr() {}

//     public entry fun add_liquidity_single(
//         lender: &signer,
//         lp_object: Object<position_v3::Info>,
//         from_a: Object<Metadata>,
//         to_b: Object<Metadata>,
//         amount_in: u64,
//         slippage_numerators: u256,
//         slippage_denominator: u256,
//         threshold_numerator: u256,
//         threshold_denominator: u256
//     ) acquires Admin {
//         let admin = borrow_global<Admin>(@admin);
//         let admin_signer = account::create_signer_with_capability(&admin.signer_cap);
//         router_v3::add_liquidity_single(
//             &admin_signer,
//             lp_object,
//             from_a,
//             to_b,
//             amount_in,
//             slippage_numerators,
//             slippage_denominator,
//             threshold_numerator,
//             threshold_denominator
//         )
//     }

//     public entry fun remove_liquidity_single(
//         lender: &signer,
//         lp_object: Object<position_v3::Info>,
//         to_a: Object<Metadata>,
//         to_b: Object<Metadata>,
//         liquidity: u128,
//         amount_a_min: u64,
//         amount_b_min: u64
//     ) {
//         abort 0; // IGNORE
//     }

//     fun close_position_internal() {}

//     inline fun create_seed_from_position_info(
//         lender: address,
//         token_a: address,
//         token_b: address,
//         fee_tier: u8,
//         tick_lower: u32,
//         tick_upper: u32
//     ): vector<u8> {
//         let _v = vector::empty<u8>();
//         _v.append(bcs::to_bytes(&lender));
//         _v.append(bcs::to_bytes(&token_a));
//         _v.append(bcs::to_bytes(&token_b));
//         _v.append(bcs::to_bytes(&fee_tier));
//         _v.append(bcs::to_bytes(&tick_lower));
//         _v.append(bcs::to_bytes(&tick_upper));
//         _v
//     }

//     // ===== VIEW FUNCTIONS =====
// }

