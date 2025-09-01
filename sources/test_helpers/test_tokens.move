module disentry::test_tokens {
    use std::string::utf8;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::signer;
    use aptos_framework::account;
    use aptos_framework::option;

    const USDC_SYMBOL: vector<u8> = b"tUSDC";
    const USDT_SYMBOL: vector<u8> = b"tUSDT";
    const INIT_SUPPLY: u128 = 1_000_000_000_000;


    struct TokenInfo has store, key {
        mint_ref: fungible_asset::MintRef,
        transfer_ref: fungible_asset::TransferRef,
        burn_ref: fungible_asset::BurnRef,
    }

    struct TokenStore has store, key {
        usdc: TokenInfo,
        usdt: TokenInfo,
    }

    public fun init(owner: &signer) {
        init_usdc(owner);
        init_usdt(owner);
    }
    
    fun init_usdc(owner: &signer) {
        let cons_ref_usdc = object::create_named_object(owner, USDC_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &cons_ref_usdc,
            option::some(INIT_SUPPLY),
            utf8(b"Test USDC"),
            utf8(USDC_SYMBOL),
            6,
            utf8(b"https://example.com/usdc.png"),
            utf8(b"https://example.com"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&cons_ref_usdc);
        let transfer_ref = fungible_asset::generate_transfer_ref(&cons_ref_usdc);
        let burn_ref = fungible_asset::generate_burn_ref(&cons_ref_usdc);

        let object_signer = object::generate_signer(&cons_ref_usdc);

        move_to(&object_signer, TokenInfo {
            mint_ref,
            transfer_ref,
            burn_ref,
        });
    }

    fun init_usdt(owner: &signer) {
        let cons_ref_usdt = object::create_named_object(owner, USDT_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &cons_ref_usdt,
            option::some(INIT_SUPPLY),
            utf8(b"Test USDT"),
            utf8(USDT_SYMBOL),
            6,
            utf8(b"https://example.com/usdt.png"),
            utf8(b"https://example.com"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&cons_ref_usdt);
        let transfer_ref = fungible_asset::generate_transfer_ref(&cons_ref_usdt);
        let burn_ref = fungible_asset::generate_burn_ref(&cons_ref_usdt);

        let object_signer = object::generate_signer(&cons_ref_usdt);
        
        move_to(&object_signer, TokenInfo {
            mint_ref,
            transfer_ref,
            burn_ref,
        });
    }
    
    inline fun get_token_info(symbol: vector<u8>): Object<TokenInfo> {
        let asset_address = object::create_object_address(&@disentry, symbol);
        object::address_to_object(asset_address)
    }

    #[view]
    public fun get_metadata(symbol: vector<u8>): Object<Metadata> {
        let asset_address = object::create_object_address(&@disentry, symbol);
        object::address_to_object<Metadata>(asset_address)
    }

    #[view]
    public fun usdc_symbol(): vector<u8> {
        USDC_SYMBOL
    }

    #[view]
    public fun usdt_symbol(): vector<u8> {
        USDT_SYMBOL
    }
    
    public fun mint_usdc(admin: &signer, to: address, amount: u64) acquires TokenInfo {
        let token_info_obj = get_token_info(USDC_SYMBOL);
        let token_info = borrow_global<TokenInfo>(object::object_address(&token_info_obj));
        let asset = get_metadata(USDC_SYMBOL);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&token_info.mint_ref, amount);
        fungible_asset::deposit_with_ref(&token_info.transfer_ref, to_wallet, fa);
    }
    public fun mint_usdt(admin: &signer, to: address, amount: u64) acquires TokenInfo {
        let token_info_obj = get_token_info(USDT_SYMBOL);
        let token_info = borrow_global<TokenInfo>(object::object_address(&token_info_obj));
        let asset = get_metadata(USDT_SYMBOL);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&token_info.mint_ref, amount);
        fungible_asset::deposit_with_ref(&token_info.transfer_ref, to_wallet, fa);
    }

    #[test(creator = @disentry)]
    fun test_basic_flow(
        creator: &signer,
    ) acquires TokenInfo {
        init(creator);
        let alice = account::create_signer_for_test(@0xA1);
        let bob = account::create_signer_for_test(@0xB1);
        let charlie = account::create_signer_for_test(@0xC1);

        mint_usdc(creator, signer::address_of(&alice), 1_000_000);
        mint_usdt(creator, signer::address_of(&bob), 2_000_000);

        let asset_usdc = get_metadata(USDC_SYMBOL);
        let asset_usdt = get_metadata(USDT_SYMBOL);
        let usdc_token_info_obj = get_token_info(USDC_SYMBOL);
        let usdt_token_info_obj = get_token_info(USDT_SYMBOL);
        let usdc_token_info = borrow_global<TokenInfo>(object::object_address(&usdc_token_info_obj));
        let usdt_token_info = borrow_global<TokenInfo>(object::object_address(&usdt_token_info_obj));

        let alice_wallet = primary_fungible_store::ensure_primary_store_exists(signer::address_of(&alice), asset_usdc);
        let bob_wallet = primary_fungible_store::ensure_primary_store_exists(signer::address_of(&bob), asset_usdt);
        assert!(primary_fungible_store::balance(signer::address_of(&alice), asset_usdc) == 1_000_000, 1);
        assert!(primary_fungible_store::balance(signer::address_of(&bob), asset_usdt) == 2_000_000, 2);

        // Test transfer
        let fa = fungible_asset::withdraw_with_ref(&usdc_token_info.transfer_ref, alice_wallet, 500_000);
        let charlie_wallet = primary_fungible_store::ensure_primary_store_exists(signer::address_of(&charlie), asset_usdc);

        fungible_asset::deposit_with_ref(&usdc_token_info.transfer_ref, charlie_wallet, fa);
        assert!(primary_fungible_store::balance(signer::address_of(&alice), asset_usdc) == 500_000, 3);
        assert!(primary_fungible_store::balance(signer::address_of(&charlie), asset_usdc) == 500_000, 4);
    }
}