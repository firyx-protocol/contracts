module firyx::math {
    use aptos_framework::math64;

    // friend firyx::core;
    friend firyx::loan_slot;
    friend firyx::deposit_slot;
    friend firyx::loan_position;

    /// ===== ERROR CODES =====
    const E_DIVISION_BY_ZERO: u64 = 1;
    const E_OVERFLOW: u64 = 2;

    /// ===== CONSTANTS =====
    const Q64: u128 = 1 << 64;
    const BPS: u64 = 10_000; // Basis points
    const PRECISION: u128 = 1_000_000_000_000;

    // ===== DECIMAL UTILS =====

    /// Convert raw integer to decimal-adjusted value
    /// 
    /// Arguments:
    /// * `amount` - The raw integer amount to be converted.
    /// * `decimals` - The number of decimal places to adjust to.
    ///
    /// Returns:
    /// * The decimal-adjusted value as u64.
    public(friend) fun to_decimals(amount: u64, decimals: u64): u64 {
        let factor = math64::pow(10, decimals);
        amount * factor
    }

    /// Convert decimal-adjusted value back to raw integer
    /// 
    /// Arguments:
    /// * `amount` - The decimal-adjusted amount to be converted back.
    /// * `decimals` - The number of decimal places that were used for adjustment.
    /// 
    /// Returns:
    /// * The raw integer amount as u64.
    public(friend) fun from_decimals(amount: u64, decimals: u64): u64 {
        let factor = math64::pow(10, decimals);
        amount / factor
    }

    public(friend) fun q64(): u128 {
        Q64
    }

    public(friend) fun bps(): u64 {
        BPS
    }

    public(friend) fun precision(): u128 {
        PRECISION
    }
}