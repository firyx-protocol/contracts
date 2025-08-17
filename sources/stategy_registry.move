/// Strategy Registry Module for ROSCA Protocol
/// 
/// This module manages different yield distribution strategies that can be applied to ROSCA pools.
/// It provides a flexible framework for registering, auditing, and using various mathematical
/// models to determine how yields are distributed among pool participants based on their positions.
/// 
/// The registry supports:
/// - Built-in strategies (linear, fibonacci, time-value-of-money, etc.)
/// - Community-contributed strategies with reputation-based approval
/// - Performance tracking and analytics
/// - Parameter customization per pool instance
/// - Creator reputation system and governance
module rosca::strategy_registry {
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use std::table::{Self, Table};
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::account;
    use aptos_framework::resource_account;

    // === ERROR CODES ===
    
    /// User is not authorized to perform this action
    const E_NOT_AUTHORIZED: u64 = 200;
    /// Strategy with this ID already exists
    const E_STRATEGY_EXISTS: u64 = 201;
    /// Strategy not found in registry
    const E_STRATEGY_NOT_FOUND: u64 = 202;
    /// Invalid parameters provided
    const E_INVALID_PARAMETERS: u64 = 203;
    /// Strategy is not currently active
    const E_STRATEGY_INACTIVE: u64 = 204;
    /// Invalid allocation percentages
    const E_INVALID_ALLOCATION: u64 = 205;
    /// Insufficient reputation score to perform action
    const E_INSUFFICIENT_REPUTATION: u64 = 206;
    /// Strategy is currently being used by pools
    const E_STRATEGY_IN_USE: u64 = 207;
    /// Invalid version format
    const E_INVALID_VERSION: u64 = 208;

    // === CONSTANTS ===
    
    /// Precision factor for percentage calculations (100.00% = 10000)
    const PRECISION: u64 = 10000;
    /// Minimum reputation score required to create community strategies
    const MIN_REPUTATION_SCORE: u64 = 500;
    /// Audit validity period in seconds (7 days)
    const STRATEGY_AUDIT_PERIOD: u64 = 604800;
    /// Maximum number of custom parameters allowed per strategy
    const MAX_CUSTOM_PARAMS: u64 = 20;

    // === CORE STRUCTS ===

    /// Definition of a customizable parameter for strategies
    struct ParameterDefinition has copy, drop, store {
        /// Name of the parameter
        param_name: String,
        /// Data type ("u64", "bool", "vector<u64>", "string")
        param_type: String,
        /// Serialized default value
        default_value: vector<u8>,
        /// Minimum allowed value (for numeric types)
        min_value: Option<u64>,
        /// Maximum allowed value (for numeric types)
        max_value: Option<u64>,
        /// Human-readable description
        description: String,
        /// Whether this parameter is required
        is_required: bool,
    }

    /// Complete configuration for a yield distribution strategy
    struct StrategyConfig has copy, drop, store {
        /// Unique identifier for the strategy
        strategy_id: String,
        /// Human-readable name
        name: String,
        /// Detailed description of the strategy
        description: String,
        /// Version string (semver format)
        version: String,
        /// Address of the strategy creator
        author: address,
        /// Optional address for custom strategy implementations
        implementation_address: Option<address>,
        
        // Strategy Parameters
        /// Schema defining all configurable parameters
        param_schema: vector<ParameterDefinition>,
        /// Default parameter values (serialized)
        default_params: Table<String, vector<u8>>,
        
        // Metadata
        /// Category: "builtin", "community", "experimental"
        category: String,
        /// Risk level from 1 (low) to 10 (high)
        risk_level: u8,
        /// User complexity level from 1 (simple) to 5 (expert)
        complexity_level: u8,
        
        // Status and Audit
        /// Whether the strategy is active and can be used
        is_active: bool,
        /// Whether the strategy has passed audit
        is_audited: bool,
        /// Timestamp when audit expires
        audit_expiry: u64,
        /// When the strategy was created
        created_time: u64,
        /// When the strategy was last updated
        last_updated: u64,
        
        // Usage Statistics
        /// Number of pools currently using this strategy
        total_pools_using: u64,
        /// Total value managed across all pools using this strategy
        total_value_managed: u64,
        /// Average performance score (0-10000 representing 0-100.00%)
        average_performance_score: u64,
        /// Historical user ratings
        user_ratings: vector<u64>,
        
        // Performance Metrics
        /// Historical performance snapshots
        historical_returns: vector<PerformanceSnapshot>,
        /// Percentage of pools that completed successfully
        success_rate: u64,
    }

    /// Snapshot of strategy performance at a point in time
    struct PerformanceSnapshot has copy, drop, store {
        /// When this snapshot was taken
        timestamp: u64,
        /// Number of active pools at this time
        pools_active: u64,
        /// Average APY across all pools
        average_apy: u64,
        /// Total yield generated
        total_yield_generated: u64,
        /// Pool completion rate
        completion_rate: u64,
        /// Average member satisfaction score
        member_satisfaction: u64,
    }

    /// Instance of a strategy applied to a specific pool
    struct StrategyInstance has copy, drop, store {
        /// ID of the strategy being used
        strategy_id: String,
        /// ID of the pool using this strategy
        pool_id: u64,
        /// Custom parameter values for this instance
        custom_parameters: Table<String, vector<u8>>,
        /// When this instance was created
        instance_created: u64,
        /// Last time distribution was recalculated
        last_recalculated: u64,
        /// Performance metrics for this specific instance
        performance_metrics: InstancePerformance,
    }

    /// Performance metrics for a specific strategy instance
    struct InstancePerformance has copy, drop, store {
        /// Actual APY achieved by this pool
        actual_apy: u64,
        /// Total yield generated
        yield_generated: u64,
        /// Member satisfaction score (0-10000)
        member_satisfaction_score: u64,
        /// Pool status: 0=active, 1=completed, 2=failed
        completion_status: u8,
        /// Number of risk events encountered
        risk_events_count: u64,
    }

    /// Profile for strategy creators with reputation system
    struct CreatorProfile has store {
        /// Creator's address
        creator_address: address,
        /// Display name chosen by creator
        display_name: String,
        /// Reputation score (0-10000)
        reputation_score: u64,
        /// Number of strategies created
        strategies_created: u64,
        /// Total value managed across all creator's strategies
        total_value_managed: u64,
        /// Success rate of creator's strategies
        success_rate: u64,
        /// Community rating average
        community_rating: u64,
        /// Achievement badges earned
        badges: vector<String>,
        /// When the creator profile was created
        creation_timestamp: u64,
    }

    /// Main registry resource storing all strategies and metadata
    struct StrategyRegistry has key {
        // Core Storage
        /// All registered strategies
        strategies: Table<String, StrategyConfig>,
        /// Active strategy instances per pool
        strategy_instances: Table<u64, StrategyInstance>,
        
        // Creator Management
        /// Creator profiles and reputation data
        creators: Table<address, CreatorProfile>,
        
        // Category Indexes for Discovery
        /// List of built-in strategy IDs
        builtin_strategies: vector<String>,
        /// List of community-approved strategy IDs
        community_strategies: vector<String>,
        /// List of experimental strategy IDs
        experimental_strategies: vector<String>,
        
        // Global Statistics
        /// Total number of strategies ever created
        total_strategies: u64,
        /// Number of currently active strategies
        active_strategies: u64,
        /// Total number of pools served
        total_pools_served: u64,
        /// Total value managed across all strategies
        total_value_managed: u64,
        
        // Governance
        /// Addresses with admin privileges
        admin_addresses: vector<address>,
        /// Addresses on the audit committee
        audit_committee: vector<address>,
        
        // Registry Metadata
        /// Current version of the registry
        registry_version: String,
        /// Last time global statistics were updated
        last_global_update: u64,
    }

    /// Strategy submission pending review (for community strategies)
    struct StrategySubmission has store {
        /// Unique submission identifier
        submission_id: String,
        /// The strategy configuration being submitted
        strategy_config: StrategyConfig,
        /// Address of the submitter
        submitter: address,
        /// When the submission was made
        submission_time: u64,
        /// Review status: 0=pending, 1=approved, 2=rejected
        review_status: u8,
        /// Comments from reviewers
        reviewer_comments: vector<String>,
        /// Community votes (address -> approve/reject)
        community_votes: Table<address, bool>,
        /// Optional audit report
        audit_results: Option<AuditReport>,
    }

    /// Detailed audit report for a strategy
    struct AuditReport has copy, drop, store {
        /// Address of the auditor
        auditor: address,
        /// Date of audit completion
        audit_date: u64,
        /// Security assessment score (1-10)
        security_score: u8,
        /// Gas efficiency score (1-10)
        gas_efficiency_score: u8,
        /// Code quality score (1-10)
        code_quality_score: u8,
        /// Overall audit score (1-10)
        overall_score: u8,
        /// Security and quality findings
        findings: vector<String>,
        /// Auditor recommendations
        recommendations: vector<String>,
        /// Certification expiry timestamp
        certification_valid_until: u64,
    }

    /// Admin capability resource
    struct RegistryAdminCap has key, store {}

    // === EVENTS ===

    /// Event emitted when a new strategy is registered
    struct StrategyRegisteredEvent has drop, store {
        /// ID of the new strategy
        strategy_id: String,
        /// Address of the creator
        creator: address,
        /// Strategy category
        category: String,
        /// Version string
        version: String,
    }

    /// Event emitted when a strategy is used by a pool
    struct StrategyUsedEvent has drop, store {
        /// ID of the strategy
        strategy_id: String,
        /// ID of the pool using it
        pool_id: u64,
        /// Total value being managed
        total_value: u64,
    }

    /// Event emitted when strategy performance is updated
    struct PerformanceUpdatedEvent has drop, store {
        /// ID of the strategy
        strategy_id: String,
        /// Number of pools using the strategy
        pool_count: u64,
        /// Current average APY
        average_apy: u64,
        /// Success rate percentage
        success_rate: u64,
    }

    /// Event emitted when a user rates a strategy
    struct StrategyRatedEvent has drop, store {
        /// ID of the strategy being rated
        strategy_id: String,
        /// Address of the rater
        rater: address,
        /// Rating score (1-10)
        rating: u8,
        /// Optional review text
        review: String,
    }

    // === INITIALIZATION ===

    /// Initialize the strategy registry module
    /// Creates the main registry resource and sets up built-in strategies
    /// @param admin - The module admin account
    fun init_module(admin: &signer) {
        let admin_addresses = vector::empty<address>();
        admin_addresses.push_back(signer::address_of(admin));
        
        let registry = StrategyRegistry {
            strategies: table::new<String, StrategyConfig>(),
            strategy_instances: table::new<u64, StrategyInstance>(),
            creators: table::new<address, CreatorProfile>(),
            
            builtin_strategies: vector::empty<String>(),
            community_strategies: vector::empty<String>(),
            experimental_strategies: vector::empty<String>(),
            
            total_strategies: 0,
            active_strategies: 0,
            total_pools_served: 0,
            total_value_managed: 0,
            
            admin_addresses,
            audit_committee: vector::empty<address>(),
            
            registry_version: string::utf8(b"1.0.0"),
            last_global_update: timestamp::now_seconds(),
        };

        move_to(admin, registry);
        move_to(admin, RegistryAdminCap {});

        // Initialize built-in strategies
        setup_builtin_strategies(admin);
    }

    // === STRATEGY REGISTRATION ===

    /// Register a new yield distribution strategy
    /// @param creator - Signer creating the strategy
    /// @param strategy_id - Unique identifier for the strategy
    /// @param name - Human-readable name
    /// @param description - Detailed description
    /// @param version - Version string
    /// @param category - Strategy category ("builtin", "community", "experimental")
    /// @param risk_level - Risk assessment (1-10)
    /// @param complexity_level - User complexity (1-5)
    /// @param param_names - Names of configurable parameters
    /// @param param_types - Data types of parameters
    /// @param param_defaults - Default values (serialized)
    /// @param param_descriptions - Parameter descriptions
    public entry fun register_strategy(
        creator: &signer,
        strategy_id: String,
        name: String,
        description: String,
        version: String,
        category: String,
        risk_level: u8,
        complexity_level: u8,
        param_names: vector<String>,
        param_types: vector<String>,
        param_defaults: vector<vector<u8>>,
        param_descriptions: vector<String>,
    ) acquires StrategyRegistry {
        let creator_addr = signer::address_of(creator);
        let registry = borrow_global_mut<StrategyRegistry>(@rosca);
        
        // Validate strategy doesn't exist
        assert!(!registry.strategies.contains(strategy_id), E_STRATEGY_EXISTS);
        
        // Validate creator reputation for community strategies
        if (category == string::utf8(b"community")) {
            assert!(registry.creators.contains(creator_addr), E_INSUFFICIENT_REPUTATION);
            let creator_profile = registry.creators.borrow(creator_addr);
            assert!(creator_profile.reputation_score >= MIN_REPUTATION_SCORE, E_INSUFFICIENT_REPUTATION);
        };

        // Build parameter schema
        let param_schema = vector::empty<ParameterDefinition>();
        let default_params = table::new<String, vector<u8>>();
        
        let i = 0;
        let param_count = param_names.length();
        while (i < param_count) {
            let param_name = param_names[i];
            let param_type = param_types[i];
            let param_default = param_defaults[i];
            let param_desc = param_descriptions[i];
            
            let param_def = ParameterDefinition {
                param_name,
                param_type,
                default_value: param_default,
                min_value: option::none<u64>(),
                max_value: option::none<u64>(),
                description: param_desc,
                is_required: true,
            };
            
            param_schema.push_back(param_def);
            default_params.add(param_name, param_default);
            i += 1;
        };

        // Create strategy configuration
        let strategy_config = StrategyConfig {
            strategy_id,
            name,
            description,
            version,
            author: creator_addr,
            implementation_address: option::none<address>(),
            
            param_schema,
            default_params,
            
            category,
            risk_level,
            complexity_level,
            
            is_active: if (category == string::utf8(b"builtin")) { true } else { false },
            is_audited: false,
            audit_expiry: 0,
            created_time: timestamp::now_seconds(),
            last_updated: timestamp::now_seconds(),
            
            total_pools_using: 0,
            total_value_managed: 0,
            average_performance_score: 0,
            user_ratings: vector::empty<u64>(),
            
            historical_returns: vector::empty<PerformanceSnapshot>(),
            success_rate: 0,
        };

        // Add to registry
        table::add(&mut registry.strategies, strategy_id, strategy_config);
        
        // Update category indexes
        if (category == string::utf8(b"builtin")) {
            vector::push_back(&mut registry.builtin_strategies, strategy_id);
        } else if (category == string::utf8(b"community")) {
            vector::push_back(&mut registry.community_strategies, strategy_id);
        } else if (category == string::utf8(b"experimental")) {
            vector::push_back(&mut registry.experimental_strategies, strategy_id);
        };

        // Update creator profile
        update_creator_profile(registry, creator_addr);
        
        // Update global stats
        registry.total_strategies = registry.total_strategies + 1;
        if (strategy_config.is_active) {
            registry.active_strategies = registry.active_strategies + 1;
        };

        // Emit event
        event::emit(StrategyRegisteredEvent {
            strategy_id,
            creator: creator_addr,
            category,
            version,
        });
    }

    // === STRATEGY INSTANCE MANAGEMENT ===

    /// Create a strategy instance for a specific pool
    /// @param strategy_id - ID of the strategy to instantiate
    /// @param pool_id - ID of the pool
    /// @param custom_param_names - Names of parameters to customize
    /// @param custom_param_values - Custom parameter values
    /// @return StrategyInstance - The created instance
    public fun create_strategy_instance(
        strategy_id: String,
        pool_id: u64,
        custom_param_names: vector<String>,
        custom_param_values: vector<vector<u8>>,
    ): StrategyInstance acquires StrategyRegistry {
        let registry = borrow_global_mut<StrategyRegistry>(@rosca);
        
        // Validate strategy exists and is active
        assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
        let strategy_config = table::borrow(&registry.strategies, strategy_id);
        assert!(strategy_config.is_active, E_STRATEGY_INACTIVE);

        // Build custom parameters table starting with defaults
        let custom_parameters = table::new<String, vector<u8>>();
        
        // Copy default parameters
        table::for_each_ref(&strategy_config.default_params, |param_name, default_value| {
            table::add(&mut custom_parameters, *param_name, *default_value);
        });
        
        // Override with custom parameters
        let i = 0;
        let custom_param_count = vector::length(&custom_param_names);
        while (i < custom_param_count) {
            let param_name = *vector::borrow(&custom_param_names, i);
            let param_value = *vector::borrow(&custom_param_values, i);
            
            // Validate parameter exists in schema
            let param_exists = validate_parameter_exists(&strategy_config.param_schema, &param_name);
            assert!(param_exists, E_INVALID_PARAMETERS);
            
            // Update parameter value
            if (table::contains(&custom_parameters, param_name)) {
                *table::borrow_mut(&mut custom_parameters, param_name) = param_value;
            } else {
                table::add(&mut custom_parameters, param_name, param_value);
            };
            
            i = i + 1;
        };

        // Create strategy instance
        let instance = StrategyInstance {
            strategy_id: strategy_id,
            pool_id,
            custom_parameters,
            instance_created: timestamp::now_seconds(),
            last_recalculated: 0,
            performance_metrics: InstancePerformance {
                actual_apy: 0,
                yield_generated: 0,
                member_satisfaction_score: 0,
                completion_status: 0,
                risk_events_count: 0,
            },
        };

        // Store instance in registry
        table::add(&mut registry.strategy_instances, pool_id, instance);
        
        // Update strategy usage statistics
        let strategy_config_mut = table::borrow_mut(&mut registry.strategies, strategy_id);
        strategy_config_mut.total_pools_using = strategy_config_mut.total_pools_using + 1;

        // Emit event
        event::emit(StrategyUsedEvent {
            strategy_id,
            pool_id,
            total_value: 0,
        });

        *table::borrow(&registry.strategy_instances, pool_id)
    }

    // === YIELD DISTRIBUTION CALCULATION ===

    /// Calculate yield distribution shares based on strategy and pool parameters
    /// @param strategy_id - ID of the strategy to use
    /// @param pool_id - ID of the pool
    /// @param total_members - Number of members in the pool
    /// @return vector<u64> - Share percentages for each position (sum to PRECISION)
    public fun calculate_distribution_shares(
        strategy_id: String,
        pool_id: u64,
        total_members: u8,
    ): vector<u64> acquires StrategyRegistry {
        let registry = borrow_global<StrategyRegistry>(@rosca);
        
        assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
        assert!(table::contains(&registry.strategy_instances, pool_id), E_STRATEGY_NOT_FOUND);
        
        let instance = table::borrow(&registry.strategy_instances, pool_id);
        
        // Route to appropriate calculation based on strategy type
        if (strategy_id == string::utf8(b"linear_compensation")) {
            calculate_linear_shares(&instance.custom_parameters, total_members)
        } else if (strategy_id == string::utf8(b"fibonacci_sequence")) {
            calculate_fibonacci_shares(total_members)
        } else if (strategy_id == string::utf8(b"time_value_money")) {
            calculate_tvm_shares(&instance.custom_parameters, total_members)
        } else if (strategy_id == string::utf8(b"risk_adjusted")) {
            calculate_risk_adjusted_shares(&instance.custom_parameters, total_members)
        } else if (strategy_id == string::utf8(b"quadratic_compensation")) {
            calculate_quadratic_shares(&instance.custom_parameters, total_members)
        } else {
            // Default to equal distribution
            calculate_equal_shares(total_members)
        }
    }

    // === PERFORMANCE TRACKING ===

    /// Update performance metrics for a strategy instance
    /// @param admin - Admin signer
    /// @param strategy_id - ID of the strategy
    /// @param pool_id - ID of the pool
    /// @param actual_apy - Actual APY achieved
    /// @param yield_generated - Total yield generated
    /// @param member_satisfaction - Member satisfaction score
    /// @param completion_status - Pool completion status
    public entry fun update_strategy_performance(
        admin: &signer,
        strategy_id: String,
        pool_id: u64,
        actual_apy: u64,
        yield_generated: u64,
        member_satisfaction: u64,
        completion_status: u8,
    ) acquires StrategyRegistry {
        let registry = borrow_global_mut<StrategyRegistry>(@rosca);
        
        // Validate admin authority
        let admin_addr = signer::address_of(admin);
        assert!(vector::contains(&registry.admin_addresses, &admin_addr), E_NOT_AUTHORIZED);

        // Update instance performance
        if (table::contains(&registry.strategy_instances, pool_id)) {
            let instance = table::borrow_mut(&mut registry.strategy_instances, pool_id);
            instance.performance_metrics.actual_apy = actual_apy;
            instance.performance_metrics.yield_generated = yield_generated;
            instance.performance_metrics.member_satisfaction_score = member_satisfaction;
            instance.performance_metrics.completion_status = completion_status;
        };

        // Update strategy-level performance
        if (table::contains(&registry.strategies, strategy_id)) {
            let strategy_config = table::borrow_mut(&mut registry.strategies, strategy_id);
            
            // Add performance snapshot
            let snapshot = PerformanceSnapshot {
                timestamp: timestamp::now_seconds(),
                pools_active: strategy_config.total_pools_using,
                average_apy: actual_apy,
                total_yield_generated: yield_generated,
                completion_rate: if (completion_status == 1) { 10000 } else { 0 },
                member_satisfaction: member_satisfaction,
            };
            
            vector::push_back(&mut strategy_config.historical_returns, snapshot);
            
            // Update running averages
            strategy_config.average_performance_score = (strategy_config.average_performance_score + actual_apy) / 2;
            
            // Emit event
            event::emit(PerformanceUpdatedEvent {
                strategy_id,
                pool_count: strategy_config.total_pools_using,
                average_apy: actual_apy,
                success_rate: strategy_config.success_rate,
            });
        };
    }

    /// Allow users to rate and review strategies
    /// @param user - User providing the rating
    /// @param strategy_id - ID of the strategy to rate
    /// @param rating - Rating score (1-10)
    /// @param review_text - Optional review text
    public entry fun rate_strategy(
        user: &signer,
        strategy_id: String,
        rating: u8,
        review_text: String,
    ) acquires StrategyRegistry {
        let registry = borrow_global_mut<StrategyRegistry>(@rosca);
        let user_addr = signer::address_of(user);
        
        assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
        assert!(rating >= 1 && rating <= 10, E_INVALID_PARAMETERS);
        
        let strategy_config = table::borrow_mut(&mut registry.strategies, strategy_id);
        
        // Add rating to history
        vector::push_back(&mut strategy_config.user_ratings, (rating as u64));
        
        // Emit event
        event::emit(StrategyRatedEvent {
            strategy_id,
            rater: user_addr,
            rating,
            review: review_text,
        });
    }

    // === BUILT-IN STRATEGY SETUP ===

    /// Initialize all built-in yield distribution strategies
    /// Called during module initialization
    /// @param admin - Admin signer
    fun setup_builtin_strategies(admin: &signer) acquires StrategyRegistry {
        // Linear Compensation Strategy - Simple incremental increases
        register_strategy(
            admin,
            string::utf8(b"linear_compensation"),
            string::utf8(b"Linear Compensation"),
            string::utf8(b"Equal increment per position with customizable base and increment"),
            string::utf8(b"1.0"),
            string::utf8(b"builtin"),
            2, // Low-medium risk
            1, // Simple complexity
            vector[string::utf8(b"base_percentage"), string::utf8(b"increment_percentage")],
            vector[string::utf8(b"u64"), string::utf8(b"u64")],
            vector[serialize_u64(1000), serialize_u64(200)], // 10% base, 2% increment
            vector[
                string::utf8(b"Base percentage for first position"),
                string::utf8(b"Increment percentage for each subsequent position")
            ],
        );

        // Fibonacci Sequence Strategy - Natural growth pattern
        register_strategy(
            admin,
            string::utf8(b"fibonacci_sequence"),
            string::utf8(b"Fibonacci Distribution"),
            string::utf8(b"Distribution based on Fibonacci sequence ratios"),
            string::utf8(b"1.0"),
            string::utf8(b"builtin"),
            3, // Medium risk
            2, // Medium complexity
            vector[string::utf8(b"multiplier")],
            vector[string::utf8(b"u64")],
            vector[serialize_u64(100)], // 1x multiplier
            vector[string::utf8(b"Multiplier for Fibonacci values")],
        );

        // Time Value of Money Strategy - Financial theory based
        register_strategy(
            admin,
            string::utf8(b"time_value_money"),
            string::utf8(b"Time Value Compensation"),
            string::utf8(b"Compensates based on time value of money principles"),
            string::utf8(b"1.0"),
            string::utf8(b"builtin"),
            2, // Low-medium risk
            3, // Medium-high complexity
            vector[string::utf8(b"discount_rate"), string::utf8(b"base_share")],
            vector[string::utf8(b"u64"), string::utf8(b"u64")],
            vector[serialize_u64(50), serialize_u64(1000)], // 0.5% monthly rate, 10% base
            vector[
                string::utf8(b"Monthly discount rate in basis points"),
                string::utf8(b"Base share percentage")
            ],
        );

        // Risk Adjusted Strategy - CAPM inspired
        register_strategy(
            admin,
            string::utf8(b"risk_adjusted"),
            string::utf8(b"Risk-Adjusted Distribution"),
            string::utf8(b"Adjusts distribution based on position risk profile"),
            string::utf8(b"1.0"),
            string::utf8(b"builtin"),
            4, // Medium-high risk
            4, // High complexity
            vector[string::utf8(b"risk_free_rate"), string::utf8(b"risk_premium")],
            vector[string::utf8(b"u64"), string::utf8(b"u64")],
            vector[serialize_u64(300), serialize_u64(200)], // 3% risk-free, 2% premium
            vector[
                string::utf8(b"Risk-free rate in basis points"),
                string::utf8(b"Risk premium for later positions")
            ],
        );

        // Quadratic Compensation Strategy - Exponential rewards for patience
        register_strategy(
            admin,
            string::utf8(b"quadratic_compensation"),
            string::utf8(b"Quadratic Growth"),
            string::utf8(b"Quadratic increase in compensation for patience"),
            string::utf8(b"1.0"),
            string::utf8(b"builtin"),
            3, // Medium risk
            3, // Medium-high complexity
            vector[string::utf8(b"base_share"), string::utf8(b"growth_factor")],
            vector[string::utf8(b"u64"), string::utf8(b"u64")],
            vector[serialize_u64(800), serialize_u64(50)], // 8% base, 0.5 growth factor
            vector[
                string::utf8(b"Base share percentage"),
                string::utf8(b"Quadratic growth factor")
            ],
        );
    }

// === STRATEGY CALCULATION IMPLEMENTATIONS ===

   /// Calculate shares using linear progression
   /// Share = base_percentage + (position * increment_percentage)
   /// @param parameters - Strategy parameters table
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Normalized share percentages
   fun calculate_linear_shares(parameters: &Table<String, vector<u8>>, total_members: u8): vector<u64> {
       let base_percentage = deserialize_u64(parameters.borrow(string::utf8(b"base_percentage")));
       let increment_percentage = deserialize_u64(parameters.borrow(string::utf8(b"increment_percentage")));
       
       let shares = vector::empty<u64>();
       let i = 0;
       
       while (i < total_members) {
           let share = base_percentage + ((i as u64) * increment_percentage);
           shares.push_back(share);
           i += 1;
       };
       
       normalize_shares(&mut shares);
       shares
   }

   /// Calculate shares using Fibonacci sequence ratios
   /// Later positions get exponentially larger shares following Fibonacci growth
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Normalized share percentages
   fun calculate_fibonacci_shares(total_members: u8): vector<u64> {
       let fib_sequence = vector[1, 1, 2, 3, 5, 8, 13, 21, 34, 55]; // Pre-computed Fibonacci
       let shares = vector::empty<u64>();
       let total_fib = 0u64;
       
       // Calculate total Fibonacci sum for proportional distribution
       let i = 0;
       while (i < total_members) {
           let fib_value = *vector::borrow(&fib_sequence, (i as u64));
           total_fib = total_fib + fib_value;
           i = i + 1;
       };
       
       // Calculate proportional shares based on Fibonacci ratios
       i = 0;
       while (i < total_members) {
           let fib_value = *vector::borrow(&fib_sequence, (i as u64));
           let share = (fib_value * PRECISION) / total_fib;
           vector::push_back(&mut shares, share);
           i = i + 1;
       };
       
       shares
   }

   /// Calculate shares using Time Value of Money principles
   /// Later positions compensated for longer waiting time using discount rate
   /// @param parameters - Strategy parameters table
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Normalized share percentages
   fun calculate_tvm_shares(parameters: &Table<String, vector<u8>>, total_members: u8): vector<u64> {
       let discount_rate = deserialize_u64(table::borrow(parameters, string::utf8(b"discount_rate")));
       let base_share = deserialize_u64(table::borrow(parameters, string::utf8(b"base_share")));
       
       let shares = vector::empty<u64>();
       let i = 0;
       
       while (i < total_members) {
           // Calculate time compensation: later positions get more for waiting longer
           let periods_to_wait = (total_members - 1 - i) as u64;
           let time_compensation = calculate_compound_factor(discount_rate, periods_to_wait);
           let share = base_share + (time_compensation * base_share) / PRECISION;
           vector::push_back(&mut shares, share);
           i = i + 1;
       };
       
       normalize_shares(&mut shares);
       shares
   }

   /// Calculate shares using risk-adjusted returns (CAPM inspired)
   /// Early positions = lower risk/return, later positions = higher risk/return
   /// @param parameters - Strategy parameters table
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Normalized share percentages
   fun calculate_risk_adjusted_shares(parameters: &Table<String, vector<u8>>, total_members: u8): vector<u64> {
       let risk_free_rate = deserialize_u64(table::borrow(parameters, string::utf8(b"risk_free_rate")));
       let risk_premium = deserialize_u64(table::borrow(parameters, string::utf8(b"risk_premium")));
       
       let shares = vector::empty<u64>();
       let i = 0;
       
       while (i < total_members) {
           // CAPM-inspired: Return = Risk_free_rate + Beta * Risk_premium
           // Early positions have lower beta (less risky), later positions higher beta
           let position_beta = if (i < total_members / 2) {
               70 // Early positions: beta < 1.0 (lower systematic risk)
           } else {
               130 // Late positions: beta > 1.0 (higher systematic risk)
           };
           
           let share = risk_free_rate + (position_beta * risk_premium) / 100;
           vector::push_back(&mut shares, share);
           i = i + 1;
       };
       
       normalize_shares(&mut shares);
       shares
   }

   /// Calculate shares using quadratic growth
   /// Rewards patience with exponentially increasing compensation
   /// @param parameters - Strategy parameters table
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Normalized share percentages
   fun calculate_quadratic_shares(parameters: &Table<String, vector<u8>>, total_members: u8): vector<u64> {
       let base_share = deserialize_u64(table::borrow(parameters, string::utf8(b"base_share")));
       let growth_factor = deserialize_u64(table::borrow(parameters, string::utf8(b"growth_factor")));
       
       let shares = vector::empty<u64>();
       let i = 0;
       
       while (i < total_members) {
           // Quadratic growth: compensation increases with position squared
           let position_squared = (i + 1) * (i + 1);
           let quadratic_bonus = (position_squared * growth_factor) / 100;
           let share = base_share + quadratic_bonus;
           vector::push_back(&mut shares, share);
           i = i + 1;
       };
       
       normalize_shares(&mut shares);
       shares
   }

   /// Calculate equal shares for all positions (fallback strategy)
   /// @param total_members - Number of pool members
   /// @return vector<u64> - Equal share percentages
   fun calculate_equal_shares(total_members: u8): vector<u64> {
       let shares = vector::empty<u64>();
       let equal_share = PRECISION / (total_members as u64);
       let i = 0;
       
       while (i < total_members) {
           vector::push_back(&mut shares, equal_share);
           i = i + 1;
       };
       
       shares
   }

   // === HELPER FUNCTIONS ===

   /// Normalize share percentages to sum exactly to PRECISION (100%)
   /// Prevents rounding errors in percentage calculations
   /// @param shares - Mutable reference to shares vector
   fun normalize_shares(shares: &mut vector<u64>) {
       let total = 0u64;
       let i = 0;
       let len = vector::length(shares);
       
       // Calculate current total
       while (i < len) {
           total = total + *vector::borrow(shares, i);
           i = i + 1;
       };
       
       // Normalize each share to sum to PRECISION (10000 = 100%)
       i = 0;
       while (i < len) {
           let current_share = *vector::borrow(shares, i);
           let normalized_share = (current_share * PRECISION) / total;
           *vector::borrow_mut(shares, i) = normalized_share;
           i = i + 1;
       };
   }

   /// Check if a parameter name exists in the strategy schema
   /// @param param_schema - Vector of parameter definitions
   /// @param param_name - Name to search for
   /// @return bool - True if parameter exists
   fun validate_parameter_exists(param_schema: &vector<ParameterDefinition>, param_name: &String): bool {
       let i = 0;
       let len = vector::length(param_schema);
       
       while (i < len) {
           let param_def = vector::borrow(param_schema, i);
           if (&param_def.param_name == param_name) {
               return true
           };
           i = i + 1;
       };
       
       false
   }

   /// Update or create creator profile with new strategy
   /// @param registry - Mutable reference to registry
   /// @param creator_addr - Address of the creator
   fun update_creator_profile(registry: &mut StrategyRegistry, creator_addr: address) {
       if (table::contains(&registry.creators, creator_addr)) {
           // Update existing profile
           let profile = table::borrow_mut(&mut registry.creators, creator_addr);
           profile.strategies_created = profile.strategies_created + 1;
       } else {
           // Create new profile
           let new_profile = CreatorProfile {
               creator_address: creator_addr,
               display_name: string::utf8(b""), // Can be updated later
               reputation_score: 1000, // Starting reputation
               strategies_created: 1,
               total_value_managed: 0,
               success_rate: 0,
               community_rating: 0,
               badges: vector::empty<String>(),
               creation_timestamp: timestamp::now_seconds(),
           };
           table::add(&mut registry.creators, creator_addr, new_profile);
       };
   }

   /// Calculate compound growth factor for time value calculations
   /// @param rate - Interest/discount rate in basis points
   /// @param periods - Number of time periods
   /// @return u64 - Compound factor scaled by PRECISION
   fun calculate_compound_factor(rate: u64, periods: u64): u64 {
       if (periods == 0) {
           return PRECISION
       };
       
       let factor = PRECISION;
       let i = 0;
       
       // Simple compound calculation: (1 + rate/PRECISION)^periods
       while (i < periods) {
           factor = (factor * (PRECISION + rate)) / PRECISION;
           i = i + 1;
       };
       
       factor
   }

   /// Serialize u64 value to bytes for parameter storage
   /// @param value - Value to serialize
   /// @return vector<u8> - Serialized bytes
   fun serialize_u64(value: u64): vector<u8> {
       let bytes = vector::empty<u8>();
       let temp = value;
       
       // Convert to little-endian bytes
       let i = 0;
       while (i < 8) {
           vector::push_back(&mut bytes, ((temp & 0xFF) as u8));
           temp = temp >> 8;
           i = i + 1;
       };
       
       bytes
   }

   /// Deserialize bytes to u64 value
   /// @param bytes - Serialized bytes
   /// @return u64 - Deserialized value
   fun deserialize_u64(bytes: &vector<u8>): u64 {
       let value = 0u64;
       let i = 0;
       
       // Convert from little-endian bytes
       while (i < vector::length(bytes) && i < 8) {
           let byte_val = (*vector::borrow(bytes, i) as u64);
           value = value + (byte_val << (i * 8));
           i = i + 1;
       };
       
       value
   }

   // === VIEW FUNCTIONS ===

   /// Get strategy configuration by ID
   /// @param strategy_id - ID of the strategy
   /// @return StrategyConfig - Strategy configuration (copy)
   public fun get_strategy_config(strategy_id: String): StrategyConfig acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
       *table::borrow(&registry.strategies, strategy_id)
   }

   /// Get strategy instance for a pool
   /// @param pool_id - ID of the pool
   /// @return StrategyInstance - Strategy instance (copy)
   public fun get_strategy_instance(pool_id: u64): StrategyInstance acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       assert!(table::contains(&registry.strategy_instances, pool_id), E_STRATEGY_NOT_FOUND);
       *table::borrow(&registry.strategy_instances, pool_id)
   }

   /// Get list of all built-in strategy IDs
   /// @return vector<String> - List of built-in strategy IDs
   public fun get_builtin_strategies(): vector<String> acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       registry.builtin_strategies
   }

   /// Get list of all community strategy IDs
   /// @return vector<String> - List of community strategy IDs
   public fun get_community_strategies(): vector<String> acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       registry.community_strategies
   }

   /// Get global registry statistics
   /// @return (u64, u64, u64, u64) - (total_strategies, active_strategies, total_pools_served, total_value_managed)
   public fun get_registry_stats(): (u64, u64, u64, u64) acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       (
           registry.total_strategies,
           registry.active_strategies,
           registry.total_pools_served,
           registry.total_value_managed
       )
   }

   /// Get creator profile information
   /// @param creator_addr - Address of the creator
   /// @return CreatorProfile - Creator profile information
   public fun get_creator_profile(creator_addr: address): CreatorProfile acquires StrategyRegistry {
       let registry = borrow_global<StrategyRegistry>(@rosca);
       assert!(table::contains(&registry.creators, creator_addr), E_STRATEGY_NOT_FOUND);
       *table::borrow(&registry.creators, creator_addr)
   }

   // === ADMIN FUNCTIONS ===

   /// Activate or deactivate a strategy (admin only)
   /// @param admin - Admin signer
   /// @param strategy_id - ID of the strategy
   /// @param active - Whether to activate or deactivate
   public entry fun set_strategy_active(
       admin: &signer,
       strategy_id: String,
       active: bool
   ) acquires StrategyRegistry {
       let registry = borrow_global_mut<StrategyRegistry>(@rosca);
       let admin_addr = signer::address_of(admin);
       
       assert!(vector::contains(&registry.admin_addresses, &admin_addr), E_NOT_AUTHORIZED);
       assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
       
       let strategy_config = table::borrow_mut(&mut registry.strategies, strategy_id);
       let was_active = strategy_config.is_active;
       strategy_config.is_active = active;
       
       // Update global active count
       if (active && !was_active) {
           registry.active_strategies = registry.active_strategies + 1;
       } else if (!active && was_active) {
           registry.active_strategies = registry.active_strategies - 1;
       };
   }

   /// Add an address to the admin list (admin only)
   /// @param admin - Current admin signer
   /// @param new_admin - Address to add as admin
   public entry fun add_admin(
       admin: &signer,
       new_admin: address
   ) acquires StrategyRegistry {
       let registry = borrow_global_mut<StrategyRegistry>(@rosca);
       let admin_addr = signer::address_of(admin);
       
       assert!(vector::contains(&registry.admin_addresses, &admin_addr), E_NOT_AUTHORIZED);
       assert!(!vector::contains(&registry.admin_addresses, &new_admin), E_STRATEGY_EXISTS);
       
       vector::push_back(&mut registry.admin_addresses, new_admin);
   }

   /// Remove an address from the admin list (admin only)
   /// @param admin - Current admin signer
   /// @param remove_admin - Address to remove from admins
   public entry fun remove_admin(
       admin: &signer,
       remove_admin: address
   ) acquires StrategyRegistry {
       let registry = borrow_global_mut<StrategyRegistry>(@rosca);
       let admin_addr = signer::address_of(admin);
       
       assert!(vector::contains(&registry.admin_addresses, &admin_addr), E_NOT_AUTHORIZED);
       
       let (found, index) = vector::index_of(&registry.admin_addresses, &remove_admin);
       assert!(found, E_STRATEGY_NOT_FOUND);
       
       vector::remove(&mut registry.admin_addresses, index);
   }

   /// Update strategy audit status (audit committee only)
   /// @param auditor - Auditor signer
   /// @param strategy_id - ID of the strategy
   /// @param audit_report - Audit report with findings
   public entry fun submit_audit_report(
       auditor: &signer,
       strategy_id: String,
       audit_report: AuditReport
   ) acquires StrategyRegistry {
       let registry = borrow_global_mut<StrategyRegistry>(@rosca);
       let auditor_addr = signer::address_of(auditor);
       
       assert!(vector::contains(&registry.audit_committee, &auditor_addr), E_NOT_AUTHORIZED);
       assert!(table::contains(&registry.strategies, strategy_id), E_STRATEGY_NOT_FOUND);
       
       let strategy_config = table::borrow_mut(&mut registry.strategies, strategy_id);
       strategy_config.is_audited = audit_report.overall_score >= 7; // Minimum passing score
       strategy_config.audit_expiry = audit_report.certification_valid_until;
       strategy_config.last_updated = timestamp::now_seconds();
   }
}