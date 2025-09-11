module fered::deposit_slot {
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_framework::math128;
    use aptos_framework::error;
    use fered::math::{bps};

    friend fered::loan_position;

    // === CONSTANTS ===
    const PRECISION: u128 = 1_000_000_000_000;

    // === ERRORS ===
    /// Deposit slot not found
    const E_DEPOSIT_SLOT_NOT_FOUND: u64 = 4001;
    /// Unauthorized access
    const E_UNAUTHORIZED: u64 = 4002;
    /// Deposit slot is not active
    const E_NOT_ACTIVE: u64 = 4003;
    /// Invalid amount
    const E_INVALID_AMOUNT: u64 = 4004;
    /// Insufficient balance for withdrawal
    const E_INSUFFICIENT_BALANCE: u64 = 4005;

    // === STRUCTS ===
    struct DepositSlot has key {
        loan_pos_addr: address,
        lender: address,
        principal: u128, // Số tiền gốc deposit
        shares: u64, // Shares ownership trong pool
        created_at_ts: u64, // Thời điểm tạo
        active: bool,
        last_deposit_ts: u64,
        last_withdraw_ts: u64
    }

    struct GlobalState has key {
        total_deposits: u64
    }

    // === INIT ===
    fun init_module(deployer: &signer) {
        move_to(deployer, GlobalState { total_deposits: 0 });
    }

    // === CORE FUNCTIONS ===

    /// Create a new deposit slot for a lender
    ///
    /// Arguments:
    /// * `lender` - Signer
    /// * `loan_pos_addr` - The address of the associated loan position
    /// * `principal` - The principal amount of the deposit
    /// * `shares` - The shares allocated for this deposit
    public(friend) fun create_deposit_slot(
        lender: &signer,
        loan_pos_addr: address,
        principal: u128,
        shares: u64
    ): Object<DepositSlot> acquires GlobalState {
        let ts = timestamp::now_seconds();
        let deposit_info = DepositSlot {
            loan_pos_addr,
            lender: signer::address_of(lender),
            principal,
            shares,
            created_at_ts: ts,
            active: true,
            last_deposit_ts: ts,
            last_withdraw_ts: 0
        };

        let lender_addr = signer::address_of(lender);
        let constructor_ref = object::create_object(lender_addr);
        let container_signer = object::generate_signer(&constructor_ref);

        move_to(&container_signer, deposit_info);

        let state = borrow_global_mut<GlobalState>(@fered);
        state.total_deposits += 1;

        let deposit_slot_obj =
            object::object_from_constructor_ref<DepositSlot>(&constructor_ref);
        object::transfer(lender, deposit_slot_obj, lender_addr);

        deposit_slot_obj
    }

    /// Deposit more liquidity to existing or new deposit slot
    ///
    /// Returns:
    /// * `new_shares` - The new shares allocated for this deposit
    /// * `total_shares` - Total shares after deposit
    /// * `position_percentage` - Percentage of total position (in basis points)
    /// * `is_new_deposit` - Whether this is a new deposit or additional deposit
    public(friend) fun deposit(
        lender: &signer,
        ds_obj: Object<DepositSlot>,
        amount: u128,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): (u64, u64, u64, bool) acquires DepositSlot {
        assert_is_owner(lender, ds_obj);

        let deposit_slot = borrow_deposit_slot_mut(ds_obj);
        assert!(deposit_slot.active, E_NOT_ACTIVE);
        assert!(amount > 0, E_INVALID_AMOUNT);

        // Calculate shares based on current pool state
        let new_shares =
            if (total_pool_shares == 0 || total_pool_liquidity == 0) {
                // First deposit in pool: shares = amount
                (amount as u64)
            } else {
                // shares = (amount * total_existing_shares) / total_existing_liquidity
                math128::mul_div(
                    amount,
                    total_pool_shares as u128,
                    total_pool_liquidity
                ) as u64
            };

        let is_new_deposit = deposit_slot.principal == 0;

        // Update deposit info
        deposit_slot.principal += amount;
        deposit_slot.shares += new_shares;
        deposit_slot.last_deposit_ts = timestamp::now_seconds();

        // Calculate position percentage in the pool (in basis points)
        let new_total_shares = total_pool_shares + new_shares;
        let position_percentage =
            if (new_total_shares > 0) {
                math128::mul_div(
                    deposit_slot.shares as u128,
                    bps() as u128,
                    new_total_shares as u128
                ) as u64
            } else {
                bps() // 100% if only deposit
            };

        (new_shares, deposit_slot.shares, position_percentage, is_new_deposit)
    }

    /// Withdraw liquidity based on amount
    ///
    /// Returns:
    /// * `shares_burned` - The shares burned for this withdrawal
    /// * `remaining_shares` - Remaining shares after withdrawal
    /// * `position_percentage` - Updated percentage of total position (in basis points)
    /// * `fully_withdrawn` - Whether the deposit is fully withdrawn
    public(friend) fun withdraw(
        lender: &signer,
        ds_obj: Object<DepositSlot>,
        amount: u128,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): (u64, u64, u64, bool) acquires DepositSlot {
        assert_is_owner(lender, ds_obj);

        let deposit_slot = borrow_deposit_slot_mut(ds_obj);
        assert!(deposit_slot.active, E_NOT_ACTIVE);
        assert!(amount > 0, E_INVALID_AMOUNT);

        // Calculate shares to burn based on current pool value
        let shares_to_burn =
            if (total_pool_liquidity > 0) {
                math128::mul_div(
                    amount,
                    total_pool_shares as u128,
                    total_pool_liquidity
                ) as u64
            } else { 0 };

        assert!(shares_to_burn <= deposit_slot.shares, E_INSUFFICIENT_BALANCE);

        // Update deposit info
        deposit_slot.shares -= shares_to_burn;
        deposit_slot.principal =
            if (deposit_slot.principal >= amount) {
                deposit_slot.principal - amount
            } else { 0 };
        deposit_slot.last_withdraw_ts = timestamp::now_seconds();

        let fully_withdrawn = deposit_slot.shares == 0;

        // If fully withdrawn, mark as inactive
        if (fully_withdrawn) {
            deposit_slot.active = false;
        };

        // Calculate updated position percentage
        let new_total_shares = total_pool_shares - shares_to_burn;
        let position_percentage =
            if (new_total_shares > 0 && !fully_withdrawn) {
                math128::mul_div(
                    deposit_slot.shares as u128,
                    bps() as u128,
                    new_total_shares as u128
                ) as u64
            } else { 0 };

        (shares_to_burn, deposit_slot.shares, position_percentage, fully_withdrawn)
    }

    // === VIEW FUNCTIONS ===

    // Basic deposit slot information
    public fun principal(deposit_slot_obj: Object<DepositSlot>): u128 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).principal
    }

    public fun shares(deposit_slot_obj: Object<DepositSlot>): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).shares
    }

    public fun timestamp_created(
        deposit_slot_obj: Object<DepositSlot>
    ): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).created_at_ts
    }

    public fun last_deposit_timestamp(
        deposit_slot_obj: Object<DepositSlot>
    ): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).last_deposit_ts
    }

    public fun last_withdraw_timestamp(
        deposit_slot_obj: Object<DepositSlot>
    ): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).last_withdraw_ts
    }

    // Status functions
    public fun is_active(deposit_slot_obj: Object<DepositSlot>): bool acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).active
    }

    public fun lender_address(
        deposit_slot_obj: Object<DepositSlot>
    ): address acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).lender
    }

    public fun loan_position_address(
        deposit_slot_obj: Object<DepositSlot>
    ): address acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).loan_pos_addr
    }

    // Global state view
    public fun total_deposits(): u64 acquires GlobalState {
        borrow_global<GlobalState>(@fered).total_deposits
    }

    // Calculate current withdrawal value based on pool state
    public fun current_withdrawal_value(
        deposit_slot_obj: Object<DepositSlot>,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): u128 acquires DepositSlot {
        let deposit_slot = borrow_deposit_slot(deposit_slot_obj);

        if (total_pool_shares == 0 || total_pool_liquidity == 0) {
            return 0
        };

        math128::mul_div(
            deposit_slot.shares as u128,
            total_pool_liquidity,
            total_pool_shares as u128
        )
    }

    // === HELPER FUNCTIONS ===

    inline fun borrow_deposit_slot(object: Object<DepositSlot>): &DepositSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<DepositSlot>(addr), E_DEPOSIT_SLOT_NOT_FOUND);
        borrow_global<DepositSlot>(addr)
    }

    inline fun borrow_deposit_slot_mut(object: Object<DepositSlot>): &mut DepositSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<DepositSlot>(addr), E_DEPOSIT_SLOT_NOT_FOUND);
        borrow_global_mut<DepositSlot>(addr)
    }

    fun assert_is_owner(signer: &signer, ds_obj: Object<DepositSlot>) {
        let signer_addr = signer::address_of(signer);
        assert!(
            object::is_owner(ds_obj, signer_addr),
            error::permission_denied(E_UNAUTHORIZED)
        );
    }

    // === TESTS ===

    #[test_only]
    fun init_for_test(deployer: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_create_deposit_slot_basic(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let loan_pos_addr = @0x456;
        let principal = 1000u128;
        let shares = 1000u64;

        let deposit_obj = create_deposit_slot(lender, loan_pos_addr, principal, shares);

        // Verify deposit slot properties
        assert!(principal(deposit_obj) == principal, 1);
        assert!(shares(deposit_obj) == shares, 2);
        assert!(is_active(deposit_obj), 3);
        assert!(lender_address(deposit_obj) == signer::address_of(lender), 4);
        assert!(total_deposits() == 1, 5);
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_deposit_first_in_pool(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 0, 0);
        let amount = 1000u128;
        let total_pool_liquidity = 0u128;
        let total_pool_shares = 0u64;

        let (new_shares, total_shares, position_pct, is_new) =
            deposit(
                lender,
                deposit_obj,
                amount,
                total_pool_liquidity,
                total_pool_shares
            );

        assert!(new_shares == (amount as u64), 1); // First deposit: shares = amount
        assert!(total_shares == (amount as u64), 2);
        assert!(principal(deposit_obj) == amount, 3);
        assert!(is_new, 4);
        assert!(position_pct == bps(), 5); // 100%
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_deposit_additional_liquidity(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let additional_amount = 500u128;
        let total_pool_liquidity = 5000u128;
        let total_pool_shares = 5000u64;

        let (new_shares, total_shares, position_pct, is_new) =
            deposit(
                lender,
                deposit_obj,
                additional_amount,
                total_pool_liquidity,
                total_pool_shares
            );

        // shares = (500 * 5000) / 5000 = 500
        assert!(new_shares == 500, 1);
        assert!(total_shares == 1500, 2);
        assert!(principal(deposit_obj) == 1500, 3);
        assert!(!is_new, 4);
        assert!(position_pct > 0, 5);
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_withdraw_partial(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let withdraw_amount = 300u128;
        let total_pool_liquidity = 5000u128;
        let total_pool_shares = 5000u64;

        let (shares_burned, remaining_shares, position_pct, fully_withdrawn) =
            withdraw(
                lender,
                deposit_obj,
                withdraw_amount,
                total_pool_liquidity,
                total_pool_shares
            );

        // shares_burned = (300 * 5000) / 5000 = 300
        assert!(shares_burned == 300, 1);
        assert!(remaining_shares == 700, 2);
        assert!(!fully_withdrawn, 3);
        assert!(is_active(deposit_obj), 4);
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_withdraw_full(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let total_pool_liquidity = 1000u128;
        let total_pool_shares = 1000u64;

        let (shares_burned, remaining_shares, position_pct, fully_withdrawn) =
            withdraw(
                lender,
                deposit_obj,
                1000u128, // full amount
                total_pool_liquidity,
                total_pool_shares
            );

        assert!(shares_burned == 1000, 1);
        assert!(remaining_shares == 0, 2);
        assert!(fully_withdrawn, 3);
        assert!(!is_active(deposit_obj), 4);
        assert!(position_pct == 0, 5);
    }

    #[test(fered = @fered, aptos_framework = @0x1, lender = @0x123)]
    fun test_current_withdrawal_value(
        fered: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(fered, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);

        // Pool has grown due to interest
        let total_pool_liquidity = 6000u128; // 20% growth
        let total_pool_shares = 5000u64;

        let withdrawal_value =
            current_withdrawal_value(
                deposit_obj,
                total_pool_liquidity,
                total_pool_shares
            );

        // value = (1000 * 6000) / 5000 = 1200
        assert!(withdrawal_value == 1200, 1);
    }
}

