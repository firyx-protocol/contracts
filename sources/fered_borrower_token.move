// === FERED LENDER TOKEN ===
module fered::fered_borrower_token {
    use std::option::{Self};
    use std::string::{Self};
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::fungible_asset::{
        Self,
        FungibleAsset,
        Metadata,
        MintRef,
        BurnRef,
        TransferRef
    };
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::function_info;
    use aptos_framework::primary_fungible_store;

    use dex_contract::pool_v3::{Self, LiquidityPoolV3};

    // friend fered::core;

    // === CONSTANTS ===
    const DECIMALS: u8 = 8;
    const TOKEN_NAME: vector<u8> = b"Fered Borrower Token";
    const TOKEN_SYMBOL: vector<u8> = b"FBT";
    const URI: vector<u8> = b"https://fered.com/lpbt-metadata.json";
    const MAX_SUPPLY: u128 = 1_000_000_000_000_000_000;
    const FEE_TIER: u8 = 2; // Index in [100, 500, 3000, 10000];
    const TICK_SPACING: u8 = 2; // Index in [1, 10, 60, 200];
    const INITIAL_TICK: u32 = 0x7fffffff - 115129;

    // === STRUCTS ===
    struct Controller has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        transfer_ref: TransferRef
    }

    struct BorrowInfo has key {
        loan_slot_addr: address,
        principal: u64,
        colleteral: u64,
        debt_idx_at_borrow: u128,
        ts: u64,
        active: bool,
        withdrawn_amount: u64,
        last_payment: u64
    }

    struct GlobalState has key {
        supply: u128,
        fbt_address: address,
        usdc_address: address,
        fbt_usdc_pool: Object<LiquidityPoolV3>
    }

    #[view]
    public fun fered_borrower_token_address(): address {
        object::create_object_address(&@fered, TOKEN_SYMBOL)
    }

    #[view]
    public fun metedata(): Object<Metadata> {
        object::address_to_object<Metadata>(fered_borrower_token_address())
    }

    // === INIT ===
    fun init_module(admin: &signer) {
        let fbt_addr = init_fungile_asset(admin);
        init_global_state(admin, fbt_addr, @usdc);
    }

    fun init_fungile_asset(admin: &signer): address {
        let constructor_ref = object::create_named_object(admin, TOKEN_NAME);
        let token_object_signer = object::generate_signer(&constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some(MAX_SUPPLY),
            string::utf8(TOKEN_NAME),
            string::utf8(TOKEN_SYMBOL),
            DECIMALS,
            string::utf8(URI),
            string::utf8(URI)
        );

        let deposit =
            function_info::new_function_info(
                admin,
                string::utf8(b"fered_borrower_token"),
                string::utf8(b"deposit")
            );

        let withdraw =
            function_info::new_function_info(
                admin,
                string::utf8(b"fered_borrower_token"),
                string::utf8(b"withdraw")
            );

        // let derived_balance =
        //     function_info::new_function_info(
        //         admin,
        //         string::utf8(b"lp_borrower_token"),
        //         string::utf8(b"derived_balance")
        //     );

        dispatchable_fungible_asset::register_dispatch_functions(
            &constructor_ref,
            option::some(withdraw),
            option::some(deposit),
            // option::some(derived_balance)
            option::none()
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);

        move_to(
            admin,
            Controller { mint_ref, burn_ref, transfer_ref }
        );

        signer::address_of(&token_object_signer)
    }

    fun init_global_state(
        admin: &signer, fbt_addr: address, usdc: address
    ) {
        let lp_object =
            pool_v3::create_pool(
                object::address_to_object<Metadata>(fbt_addr),
                object::address_to_object<Metadata>(usdc),
                FEE_TIER,
                INITIAL_TICK
            );

        move_to(
            admin,
            GlobalState {
                supply: 0,
                fbt_address: fbt_addr,
                usdc_address: usdc,
                fbt_usdc_pool: lp_object
            }
        );
    }

    #[test_only]
    fun init_global_state_for_test(
        admin: &signer, fbt_addr: address, usdc: address
    ) {
        let lp_object =
            pool_v3::create_pool(
                object::address_to_object<Metadata>(@0xa),
                object::address_to_object<Metadata>(@0xa),
                FEE_TIER,
                INITIAL_TICK
            );

        move_to(
            admin,
            GlobalState {
                supply: 0,
                fbt_address: fbt_addr,
                usdc_address: usdc,
                fbt_usdc_pool: lp_object
            }
        );
    }

    // // === FRIEND FUNCTIONS ===
    public(friend) fun mint(
        borrower: address,
        amount: u64,
        loan_slot_addr: address,
        principal: u64,
        colleteral: u64,
        debt_idx_at_borrow: u128
    ) acquires GlobalState, Controller {
        let global_state = borrow_global_mut<GlobalState>(fered_borrower_token_address());
        let controller = borrow_global<Controller>(fered_borrower_token_address());
        let fa = fungible_asset::mint(&controller.mint_ref, amount);
        primary_fungible_store::deposit_with_ref(&controller.transfer_ref, borrower, fa);

        // Store metadata about this token
        let constructor_ref = object::create_object(borrower);
        let object_signer = object::generate_signer(&constructor_ref);
        let borrower_token_info =
            object::object_from_constructor_ref<BorrowInfo>(&constructor_ref);

        move_to(
            &object_signer,
            BorrowInfo {
                loan_slot_addr,
                principal,
                colleteral,
                debt_idx_at_borrow,
                ts: aptos_framework::timestamp::now_seconds(),
                active: true,
                withdrawn_amount: 0,
                last_payment: 0
            }
        );

        object::transfer(&object_signer, borrower_token_info, borrower);

        global_state.supply +=(amount as u128);
    }

    public(friend) fun burn(borrower: address, amount: u64) acquires GlobalState, Controller {
        let global_state = borrow_global_mut<GlobalState>(fered_borrower_token_address());
        let controller = borrow_global<Controller>(fered_borrower_token_address());
        let fa =
            primary_fungible_store::withdraw_with_ref(
                &controller.transfer_ref, borrower, amount
            );
        fungible_asset::burn(&controller.burn_ref, fa);

        global_state.supply -=(amount as u128);
    }

    // === DFA FUNCTIONS ===
    public fun deposit<T: key>(
        store: Object<T>, fa: FungibleAsset, transfer_ref: &TransferRef
    ) {
        // let amount = fungible_asset::amount(&fa);
        // let store_addr = object::object_address(&store);

        // // if (object::object_exists<BorrowInfo>(store_addr)) {
        // //     let store_addr = object::object_address(&store);
        // //     let info = borrow_global<BorrowInfo>(store_addr);
        // // };

        // fa
        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    public fun withdraw<T: key>(
        store: Object<T>, amount: u64, transfer_ref: &TransferRef
    ): FungibleAsset {
        let store_addr = object::object_address(&store);

        let fa =
            primary_fungible_store::withdraw_with_ref(transfer_ref, store_addr, amount);
        fa
    }

    // public fun derived_balance<T: key>(store: Object<T>): u64 acquires Controller {
    //     let store_addr = object::object_address(&store);
    //     let base_balance = fungible_asset::balance_internal(store_addr);
    //     let owner = extract_store_owner(store_addr);

    //     // Show net claimable yield
    //     let available_yield = calculate_available_yield(owner);
    //     let outstanding_fees = calculate_outstanding_fees(owner);

    //     let net_claimable =
    //         if (available_yield > outstanding_fees) {
    //             available_yield - outstanding_fees
    //         } else { 0 };

    //     base_balance + (net_claimable as u64)
    // }

    // public(friend) fun update_borrow_info_principal(
    //     fa: &FungibleAsset,
    //     new_principal: u64,
    // ) acquires BorrowInfo {

    // }

    #[test_only]
    fun init_for_test(admin: &signer) {
        init_fungile_asset(admin);
    }

    #[
        test(
            fered = @fered,
            borrower = @0x123,
            usdc = @usdc,
            loan_slot = @0x456
        )
    ]
    fun test_basic_flow(
        fered: &signer,
        borrower: &signer,
        usdc: address,
        loan_slot: address
    ) acquires GlobalState, Controller {
        init_for_test(fered);
        init_global_state_for_test(fered, fered_borrower_token_address(), usdc);
        mint(
            signer::address_of(borrower),
            1_000_000,
            loan_slot,
            800_000,
            1_000_000,
            123456789
        );
        // burn(signer::address_of(borrower), 500_000);
        // mint other token for borrower
        mint(
            signer::address_of(borrower),
            2_000_000,
            loan_slot,
            1_600_000,
            2_000_000,
            223456789
        );
    }
}

