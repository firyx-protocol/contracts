// // === FERED LENDER TOKEN ===
// module fered::fered_lender_token {
//     use std::option::{Self, Option};
//     use std::string::{Self, String};
//     use std::signer;
//     use aptos_framework::object::{Self, Object};
//     use aptos_framework::fungible_asset::{
//         Self,
//         Metadata,
//         MintRef,
//         BurnRef,
//         TransferRef,
//         FungibleStore
//     };
//     use aptos_framework::dispatchable_fungible_asset;
//     use aptos_framework::primary_fungible_store;

//     friend fered::core;

//     // === CONSTANTS ===
//     const DECIMALS: u8 = 8;
//     const TOKEN_NAME: vector<u8> = b"Fered Lender Token";
//     const TOKEN_SYMBOL: vector<u8> = b"FLT";
//     const URI: vector<u8> = b"https://fered.com/fpt-metadata.json";
//     const MAX_SUPPLY: u128 = 1_000_000_000_000_000_000;

//     // === STRUCTS ===
//     struct Controller has key {
//         mint_ref: MintRef,
//         burn_ref: BurnRef,
//         transfer_ref: TransferRef
//     }

//     struct LenderTokenInfo has key {
//         position_id: u64,
//         original_amount: u64,
//         duration: u64,
//         created_at: u64,
//     }

//     // === INIT ===
//     fun init_module(admin: &signer) {
//         let constructor_ref = object::create_named_object(admin, TOKEN_NAME);

//         primary_fungible_store::create_primary_store_enabled_fungible_asset(
//             &constructor_ref,
//             option::some(MAX_SUPPLY),
//             string::utf8(TOKEN_NAME),
//             string::utf8(TOKEN_SYMBOL),
//             DECIMALS,
//             string::utf8(URI),
//             string::utf8(URI)
//         );

//         let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
//         let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
//         let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);

//         move_to(
//             admin,
//             Controller { mint_ref, burn_ref, transfer_ref }
//         );
//     }

//     // // === FRIEND FUNCTIONS ===
//     public(friend) fun mint(
//         lender: address, amount: u64, position_id: u64
//     ) acquires Controller {
//         let controller = borrow_global<Controller>(@fered);
//         let fa = fungible_asset::mint(&controller.mint_ref, amount);
//         primary_fungible_store::deposit(lender, fa);

//         // Store metadata about this token
//         // Note: This is simplified - would need proper token-specific metadata storage
//     }

//     public(friend) fun burn(lender: address, amount: u64) acquires Controller {
//         let controller = borrow_global<Controller>(@fered);
//         // let fa = primary_fungible_store::withdraw_with_ref(&controller.transfer_ref
//         // fungible_asset::burn(&controller.burn_ref, fa);
//     }

//     // === DFA FUNCTIONS ===
//     /// Called when lender receives yields from LP position
//     // public fun deposit(
//     //     store: &mut FungibleStore, fa: fungible_asset::FungibleAsset
//     // ) {
//     //     let amount = fungible_asset::amount(&fa);
//     //     fungible_asset::deposit(store, fa);

//     //     // TODO: Implement yield claiming logic
//     //     // - Calculate yields earned from Hyperion position
//     //     // - Account for any borrowed portions
//     //     // - Distribute accordingly
//     // }

//     // public fun withdraw(store: &mut FungibleStore, amount: u64): fungible_asset::FungibleAsset {
//     //     // TODO: Implement any withdrawal restrictions or logic
//     //     fungible_asset::withdraw(store, amount)
//     // }

//     // public fun transfer(
//     //     from: &mut FungibleStore,
//     //     to: &mut FungibleStore,
//     //     amount: u64
//     // ) {
//     //     let fa = fungible_asset::withdraw(from, amount);
//     //     fungible_asset::deposit(to, fa);

//     //     // TODO: Transfer position ownership if applicable
//     // }
// }

