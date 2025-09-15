module firyx::events {
    use aptos_framework::event;
    use aptos_framework::object::Object;
    use aptos_framework::fungible_asset::Metadata;

    friend firyx::loan_position;
    friend firyx::deposit_slot;
    friend firyx::loan_slot;

    // === LOAN POSITION EVENTS ===

    #[event]
    struct LoanPositionCreated has drop, store {
        position: address,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_fee: Object<Metadata>,
        fee_tier: u8,
        tick_lower: u32,
        tick_upper: u32,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u8,
        created_at_ts: u64
    }

    #[event]
    struct LiquidityDeposited has drop, store {
        position: address,
        lender: address,
        deposit_slot: address,
        amount: u128,
        shares: u64,
        total_liquidity: u128,
        total_shares: u128,
        utilization: u64,
        timestamp: u64
    }

    #[event]
    struct LiquidityBorrowed has drop, store {
        position: address,
        borrower: address,
        loan_slot: address,
        amount: u64,
        reserve: u64,
        duration_idx: u8,
        debt_idx_at_borrow: u128,
        new_utilization: u64,
        total_borrowed: u64,
        available_borrow: u64,
        timestamp: u64
    }

    #[event]
    struct YieldClaimed has drop, store {
        position: address,
        claimer: address,
        loan_slot: address,
        yield_amount: u128,
        fee_asset_a_amount: u64,
        fee_asset_b_amount: u64,
        total_reward_assets: u64,
        timestamp: u64
    }

    #[event]
    struct DebtIndexUpdated has drop, store {
        position: address,
        old_debt_idx: u128,
        new_debt_idx: u128,
        apr: u64,
        time_elapsed: u64,
        timestamp: u64
    }

    // === DEPOSIT SLOT EVENTS ===

    #[event]
    struct DepositSlotCreated has drop, store {
        deposit_slot: address,
        lender: address,
        loan_position: address,
        principal: u128,
        shares: u64,
        timestamp: u64
    }

    #[event]
    struct DepositAdded has drop, store {
        deposit_slot: address,
        lender: address,
        amount: u128,
        new_shares: u64,
        total_shares: u64,
        total_principal: u128,
        position_percentage: u64,
        is_new_deposit: bool,
        timestamp: u64
    }

    #[event]
    struct DepositWithdrawn has drop, store {
        deposit_slot: address,
        lender: address,
        amount: u128,
        shares_burned: u64,
        remaining_shares: u64,
        remaining_principal: u128,
        position_percentage: u64,
        fully_withdrawn: bool,
        timestamp: u64
    }

    // === LOAN SLOT EVENTS ===

    #[event]
    struct LoanSlotCreated has drop, store {
        loan_slot: address,
        borrower: address,
        loan_position: address,
        principal: u128,
        original_principal: u128,
        share: u128,
        reserve: u64,
        debt_idx_at_borrow: u128,
        timestamp: u64
    }

    #[event]
    struct LoanRepaid has drop, store {
        loan_slot: address,
        borrower: address,
        amount: u64,
        principal_portion: u64,
        interest_portion: u64,
        remaining_principal: u128,
        loan_fully_repaid: bool,
        debt_idx: u128,
        timestamp: u64
    }

    #[event]
    struct LoanWithdrawn has drop, store {
        loan_slot: address,
        borrower: address,
        amount: u64,
        reserve_withdrawn: u64,
        principal_portion: u64,
        interest_portion: u64,
        remaining_principal: u128,
        loan_fully_repaid: bool,
        timestamp: u64
    }

    // === EMIT FUNCTIONS ===

    // Loan Position Events
    public(friend) fun emit_loan_position_created(
        position: address,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_fee: Object<Metadata>,
        fee_tier: u8,
        tick_lower: u32,
        tick_upper: u32,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u8,
        created_at_ts: u64
    ) {
        event::emit(LoanPositionCreated {
            position,
            token_a,
            token_b,
            token_fee,
            fee_tier,
            tick_lower,
            tick_upper,
            slope_before_kink,
            slope_after_kink,
            kink_utilization,
            risk_factor,
            created_at_ts
        });
    }

    public(friend) fun emit_liquidity_deposited(
        position: address,
        lender: address,
        deposit_slot: address,
        amount: u128,
        shares: u64,
        total_liquidity: u128,
        total_shares: u128,
        utilization: u64,
        timestamp: u64
    ) {
        event::emit(LiquidityDeposited {
            position,
            lender,
            deposit_slot,
            amount,
            shares,
            total_liquidity,
            total_shares,
            utilization,
            timestamp
        });
    }

    public(friend) fun emit_liquidity_borrowed(
        position: address,
        borrower: address,
        loan_slot: address,
        amount: u64,
        reserve: u64,
        duration_idx: u8,
        debt_idx_at_borrow: u128,
        new_utilization: u64,
        total_borrowed: u64,
        available_borrow: u64,
        timestamp: u64
    ) {
        event::emit(LiquidityBorrowed {
            position,
            borrower,
            loan_slot,
            amount,
            reserve,
            duration_idx,
            debt_idx_at_borrow,
            new_utilization,
            total_borrowed,
            available_borrow,
            timestamp
        });
    }

    public(friend) fun emit_yield_claimed(
        position: address,
        claimer: address,
        loan_slot: address,
        yield_amount: u128,
        fee_asset_a_amount: u64,
        fee_asset_b_amount: u64,
        total_reward_assets: u64,
        timestamp: u64
    ) {
        event::emit(YieldClaimed {
            position,
            claimer,
            loan_slot,
            yield_amount,
            fee_asset_a_amount,
            fee_asset_b_amount,
            total_reward_assets,
            timestamp
        });
    }

    public(friend) fun emit_debt_index_updated(
        position: address,
        old_debt_idx: u128,
        new_debt_idx: u128,
        apr: u64,
        time_elapsed: u64,
        timestamp: u64
    ) {
        event::emit(DebtIndexUpdated {
            position,
            old_debt_idx,
            new_debt_idx,
            apr,
            time_elapsed,
            timestamp
        });
    }

    // Deposit Slot Events
    public(friend) fun emit_deposit_slot_created(
        deposit_slot: address,
        lender: address,
        loan_position: address,
        principal: u128,
        shares: u64,
        timestamp: u64
    ) {
        event::emit(DepositSlotCreated {
            deposit_slot,
            lender,
            loan_position,
            principal,
            shares,
            timestamp
        });
    }

    public(friend) fun emit_deposit_added(
        deposit_slot: address,
        lender: address,
        amount: u128,
        new_shares: u64,
        total_shares: u64,
        total_principal: u128,
        position_percentage: u64,
        is_new_deposit: bool,
        timestamp: u64
    ) {
        event::emit(DepositAdded {
            deposit_slot,
            lender,
            amount,
            new_shares,
            total_shares,
            total_principal,
            position_percentage,
            is_new_deposit,
            timestamp
        });
    }

    public(friend) fun emit_deposit_withdrawn(
        deposit_slot: address,
        lender: address,
        amount: u128,
        shares_burned: u64,
        remaining_shares: u64,
        remaining_principal: u128,
        position_percentage: u64,
        fully_withdrawn: bool,
        timestamp: u64
    ) {
        event::emit(DepositWithdrawn {
            deposit_slot,
            lender,
            amount,
            shares_burned,
            remaining_shares,
            remaining_principal,
            position_percentage,
            fully_withdrawn,
            timestamp
        });
    }

    // Loan Slot Events
    public(friend) fun emit_loan_slot_created(
        loan_slot: address,
        borrower: address,
        loan_position: address,
        principal: u128,
        original_principal: u128,
        share: u128,
        reserve: u64,
        debt_idx_at_borrow: u128,
        timestamp: u64
    ) {
        event::emit(LoanSlotCreated {
            loan_slot,
            borrower,
            loan_position,
            principal,
            original_principal,
            share,
            reserve,
            debt_idx_at_borrow,
            timestamp
        });
    }

    public(friend) fun emit_loan_repaid(
        loan_slot: address,
        borrower: address,
        amount: u64,
        principal_portion: u64,
        interest_portion: u64,
        remaining_principal: u128,
        loan_fully_repaid: bool,
        debt_idx: u128,
        timestamp: u64
    ) {
        event::emit(LoanRepaid {
            loan_slot,
            borrower,
            amount,
            principal_portion,
            interest_portion,
            remaining_principal,
            loan_fully_repaid,
            debt_idx,
            timestamp
        });
    }

    public(friend) fun emit_loan_withdrawn(
        loan_slot: address,
        borrower: address,
        amount: u64,
        reserve_withdrawn: u64,
        principal_portion: u64,
        interest_portion: u64,
        remaining_principal: u128,
        loan_fully_repaid: bool,
        timestamp: u64
    ) {
        event::emit(LoanWithdrawn {
            loan_slot,
            borrower,
            amount,
            reserve_withdrawn,
            principal_portion,
            interest_portion,
            remaining_principal,
            loan_fully_repaid,
            timestamp
        });
    }
}
