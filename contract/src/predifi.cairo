#[starknet::contract]
pub mod Predifi {
    // Cairo imports
    use core::hash::{HashStateExTrait, HashStateTrait};
    use core::pedersen::PedersenTrait;
    use core::poseidon::PoseidonTrait;
    use core::byte_array::ByteArray;
    // oz imports
    use openzeppelin::access::accesscontrol::AccessControlComponent;
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc20::interface::{
        IERC20Dispatcher, IERC20DispatcherTrait
    };
    use starknet::storage::{Map, Vec, VecTrait};
    use starknet::storage::StorageAccess;
    use starknet::storage::StorageBaseAddress;
    use starknet::{
        ContractAddress, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use crate::base::errors::Errors::{
        AMOUNT_ABOVE_MAXIMUM, AMOUNT_BELOW_MINIMUM, INACTIVE_POOL, INVALID_POOL_OPTION,
    };

    // package imports
    use crate::base::types::{Category, Pool, PoolDetails, PoolOdds, Status, UserStake};
    use crate::interfaces::ipredifi::IPredifi;

    // 1 STRK in WEI
    const ONE_STRK: u256 = 1_000_000_000_000_000_000;

    // 200 PREDIFI TOKEN in WEI
    const MIN_STAKE_AMOUNT: u256 = 200_000_000_000_000_000_000;

    // Validator role
    const VALIDATOR_ROLE: felt252 = selector!("VALIDATOR_ROLE");
    const ADMIN_ROLE: felt252 = selector!("ADMIN_ROLE");

    // components definition
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // AccessControl
    #[abi(embed_v0)]
    impl AccessControlImpl =
        AccessControlComponent::AccessControlImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

    // SRC5
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[storage]
    pub struct Storage {
        pools: Map<u256, PoolDetails>, // pool id to pool details struct
        pool_ids: Vec<u256>,
        pool_count: u256, // number of pools available totally
        pool_odds: Map<u256, PoolOdds>,
        pool_stakes: Map<u256, UserStake>,
        pool_vote: Map<u256, bool>, // pool id to vote
        user_stakes: Map<(u256, ContractAddress), UserStake>, // Mapping user -> stake details
        token_addr: ContractAddress,
        #[substorage(v0)]
        pub accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        validators: Vec<ContractAddress>,
        user_hash_poseidon: felt252,
        user_hash_pedersen: felt252,
        nonce: felt252,
        protocol_treasury: u256,
        creator_treasuries: Map<ContractAddress, u256>,
        validator_fee: Map<u256, u256>,
        validator_treasuries: Map<
            ContractAddress, u256,
        >, // Validator address to their accumulated fees
        pool_outcomes: Map<
            u256, bool,
        >, // Pool ID to outcome (true = option2 won, false = option1 won)
        pool_resolved: Map<u256, bool>,
        user_pools: Map<
            (ContractAddress, u256), bool,
        >, // Mapping (user, pool_id) -> has_participated
        user_pool_count: Map<
            ContractAddress, u256,
        >, // Tracks how many pools each user has participated in
        user_participated_pools: Map<
            (ContractAddress, u256), bool,
        >, // Maps (user, pool_id) to participation status
        user_pool_ids: Map<(ContractAddress, u256), u256>, // Maps (user, index) -> pool_id
        user_pool_ids_count: Map<
            ContractAddress, u256,
        >, // Tracks how many pool IDs are stored for each user
        // Mapping to track which validators are assigned to which pools
        pool_validator_assignments: Map<u256, (ContractAddress, ContractAddress)>,
    }

    // Events
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BetPlaced: BetPlaced,
        UserStaked: UserStaked,
        FeesCollected: FeesCollected,
        PoolStateTransition: PoolStateTransition,
        PoolResolved: PoolResolved,
        FeeWithdrawn: FeeWithdrawn,
        ValidatorsAssigned: ValidatorsAssigned,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct BetPlaced {
        pool_id: u256,
        address: ContractAddress,
        option: felt252,
        amount: u256,
        shares: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct UserStaked {
        pool_id: u256,
        address: ContractAddress,
        amount: u256,
    }
    #[derive(Drop, starknet::Event)]
    struct FeesCollected {
        fee_type: felt252,
        pool_id: u256,
        recipient: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct PoolStateTransition {
        pool_id: u256,
        previous_status: Status,
        new_status: Status,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct PoolResolved {
        pool_id: u256,
        winning_option: bool,
        total_payout: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct FeeWithdrawn {
        fee_type: felt252,
        recipient: ContractAddress,
        amount: u256,
    }


    #[derive(Drop, starknet::Event)]
    struct ValidatorsAssigned {
        pool_id: u256,
        validator1: ContractAddress,
        validator2: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, Hash)]
    struct HashingProperties {
        username: felt252,
        password: felt252,
    }

    #[derive(Drop, Hash)]
    struct Hashed {
        id: felt252,
        login: HashingProperties,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        token_addr: ContractAddress,
        validator: ContractAddress,
        admin: ContractAddress,
    ) {
        self.token_addr.write(token_addr);
        self.accesscontrol._grant_role(ADMIN_ROLE, admin);
        self.accesscontrol._grant_role(VALIDATOR_ROLE, validator)
    }

    #[abi(embed_v0)]
    impl predifi of IPredifi<ContractState> {
        fn create_pool(
            ref self: ContractState,
            poolName: felt252,
            poolType: Pool,
            poolDescription: ByteArray,
            poolImage: ByteArray,
            poolEventSourceUrl: ByteArray,
            poolStartTime: u64,
            poolLockTime: u64,
            poolEndTime: u64,
            option1: felt252,
            option2: felt252,
            minBetAmount: u256,
            maxBetAmount: u256,
            creatorFee: u8,
            isPrivate: bool,
            category: Category,
        ) -> u256 {
            // Step 1: Validate all input parameters
            Private::validate_pool_parameters(
                ref self,
                poolStartTime,
                poolLockTime,
                poolEndTime,
                minBetAmount,
                maxBetAmount,
                creatorFee
            );

            let creator_address = get_caller_address();
            
            // Step 2: Handle fee collection
            self.collect_pool_creation_fee(creator_address);

            // Step 3: Generate unique pool ID
            let pool_id = Private::generate_unique_pool_id(ref self);

            // Step 4: Create and store pool data
            let pool_details = Private::create_pool_details(
                ref self,
                poolName,
                poolType,
                poolDescription,
                poolImage,
                poolEventSourceUrl,
                poolStartTime,
                poolLockTime,
                poolEndTime,
                option1,
                option2,
                minBetAmount,
                maxBetAmount,
                creatorFee,
                isPrivate,
                category
            );
            
            // Step 5: Store pool data and initialize related data
            Private::store_pool_data(ref self, pool_id, pool_details);

            // Step 6: Setup pool validators and odds
            Private::setup_pool_validators_and_odds(ref self, pool_id);

            pool_id
        }

        fn pool_count(self: @ContractState) -> u256 {
            self.pool_count.read()
        }

        fn get_pool_creator(self: @ContractState, pool_id: u256) -> ContractAddress {
            let pool = self.pools.read(pool_id);
            pool.address
        }

        fn pool_odds(self: @ContractState, pool_id: u256) -> PoolOdds {
            self.pool_odds.read(pool_id)
        }

        fn get_pool(self: @ContractState, pool_id: u256) -> PoolDetails {
            self.pools.read(pool_id)
        }

        /// This can be called by anyone to update the state of a pool
        fn update_pool_state(ref self: ContractState, pool_id: u256) -> Status {
            let pool = self.pools.read(pool_id);
            assert(pool.exists, 'Pool does not exist');

            let current_status = pool.status;
            let current_time = get_block_timestamp();
            let mut new_status = current_status;

            // Determine the new status based on current time and pool timestamps
            if current_time >= pool.poolEndTime {
                if current_status == Status::Active || current_status == Status::Locked {
                    new_status = Status::Settled;
                } else if current_status == Status::Settled
                    && current_time >= (pool.poolEndTime + 86400) {
                    new_status = Status::Closed;
                }
            } else if current_time >= pool.poolLockTime && current_status == Status::Active {
                new_status = Status::Locked;
            }

            // Only update if there's a change in status
            if new_status != current_status {
                // Update the pool status
                let mut updated_pool = pool;
                updated_pool.status = new_status;
                self.pools.write(pool_id, updated_pool);

                // Emit event for the state transition
                let transition_event = PoolStateTransition {
                    pool_id, previous_status: current_status, new_status, timestamp: current_time,
                };
                self.emit(Event::PoolStateTransition(transition_event));
            }

            // Return the (potentially updated) status
            if new_status != current_status {
                new_status
            } else {
                current_status
            }
        }

        /// Manually update the state of a pool - can only be called by admin or validator
        fn manually_update_pool_state(
            ref self: ContractState, pool_id: u256, new_status: Status,
        ) -> Status {
            let pool = self.pools.read(pool_id);
            assert(pool.exists, 'Pool does not exist');

            // Check if caller has appropriate role (admin or validator)
            let caller = get_caller_address();
            let is_admin = self.accesscontrol.has_role(ADMIN_ROLE, caller);
            let is_validator = self.accesscontrol.has_role(VALIDATOR_ROLE, caller);
            assert(is_admin || is_validator, 'Caller not authorized');

            // Enforce status transition rules
            let current_status = pool.status;

            // Don't update if status is the same
            if new_status == current_status {
                return current_status;
            }

            // Check for invalid transitions
            let is_valid_transition = if is_admin {
                !(current_status == Status::Locked && new_status == Status::Active)
                    && !(current_status == Status::Settled
                        && (new_status == Status::Active || new_status == Status::Locked))
                    && !(current_status == Status::Closed)
            } else {
                // Active -> Locked -> Settled -> Closed
                (current_status == Status::Active && new_status == Status::Locked)
                    || (current_status == Status::Locked && new_status == Status::Settled)
                    || (current_status == Status::Settled && new_status == Status::Closed)
            };

            assert(is_valid_transition, 'Invalid state transition');

            // Update the pool status
            let mut updated_pool = pool;
            updated_pool.status = new_status;
            self.pools.write(pool_id, updated_pool);

            // Emit event for the manual state transition
            let current_time = get_block_timestamp();
            let transition_event = PoolStateTransition {
                pool_id, previous_status: current_status, new_status, timestamp: current_time,
            };
            self.emit(Event::PoolStateTransition(transition_event));

            new_status
        }

        fn vote(ref self: ContractState, pool_id: u256, option: felt252, amount: u256) {
            let pool = self.pools.read(pool_id);
            let option1: felt252 = pool.option1;
            let option2: felt252 = pool.option2;
            assert(option == option1 || option == option2, INVALID_POOL_OPTION);
            assert(pool.status == Status::Active, INACTIVE_POOL);
            assert(amount >= pool.minBetAmount, AMOUNT_BELOW_MINIMUM);
            assert(amount <= pool.maxBetAmount, AMOUNT_ABOVE_MAXIMUM);

            // Transfer betting amount from the user to the contract
            let caller = get_caller_address();
            let dispatcher = IERC20Dispatcher { contract_address: self.token_addr.read() };

            // Check balance and allowance
            let user_balance = dispatcher.balance_of(caller);
            assert(user_balance >= amount, 'Insufficient balance');

            let contract_address = get_contract_address();
            let allowed_amount = dispatcher.allowance(caller, contract_address);
            assert(allowed_amount >= amount, 'Insufficient allowance');

            // Transfer the tokens
            dispatcher.transfer_from(caller, contract_address, amount);

            let mut pool = self.pools.read(pool_id);
            if option == option1 {
                pool.totalStakeOption1 += amount;
                pool
                    .totalSharesOption1 += Private::calculate_shares(
                        ref self,
                        amount, 
                        pool.totalStakeOption1, 
                        pool.totalStakeOption2
                    );
            } else {
                pool.totalStakeOption2 += amount;
                pool
                    .totalSharesOption2 += Private::calculate_shares(
                        ref self,
                        amount, 
                        pool.totalStakeOption2, 
                        pool.totalStakeOption1
                    );
            }
            pool.totalBetAmountStrk += amount;
            pool.totalBetCount += 1;

            // Update pool odds
            let odds = Private::calculate_odds(
                ref self, 
                pool.pool_id, 
                pool.totalStakeOption1, 
                pool.totalStakeOption2
            );
            self.pool_odds.write(pool_id, odds);

            // Calculate the user's shares
            let shares: u256 = if option == option1 {
                Private::calculate_shares(
                    ref self, 
                    amount, 
                    pool.totalStakeOption1, 
                    pool.totalStakeOption2
                )
            } else {
                Private::calculate_shares(
                    ref self, 
                    amount, 
                    pool.totalStakeOption2, 
                    pool.totalStakeOption1
                )
            };

            // Store user stake
            let user_stake = UserStake {
                option: option == option2,
                amount: amount,
                shares: shares,
                timestamp: get_block_timestamp(),
            };
            let address: ContractAddress = get_caller_address();
            self.user_stakes.write((pool.pool_id, address), user_stake);
            self.pool_vote.write(pool.pool_id, option == option2);
            self.pool_stakes.write(pool.pool_id, user_stake);
            self.pools.write(pool.pool_id, pool);
            Private::track_user_participation(ref self, address, pool_id);
            // Emit event
            self.emit(Event::BetPlaced(BetPlaced { pool_id, address, option, amount, shares }));
        }

        fn stake(ref self: ContractState, pool_id: u256, amount: u256) {
            assert(amount >= MIN_STAKE_AMOUNT, 'stake amount too low');
            let address: ContractAddress = get_caller_address();

            // Transfer stake amount from user to contract
            let dispatcher = IERC20Dispatcher { contract_address: self.token_addr.read() };

            // Check balance and allowance
            let user_balance = dispatcher.balance_of(address);
            assert(user_balance >= amount, 'Insufficient balance');

            let contract_address = get_contract_address();
            let allowed_amount = dispatcher.allowance(address, contract_address);
            assert(allowed_amount >= amount, 'Insufficient allowance');

            // Transfer the tokens
            dispatcher.transfer_from(address, contract_address, amount);

            // Add to previous stake if any
            let mut stake = self.user_stakes.read((pool_id, address));
            stake.amount = amount + stake.amount;
            // write the new stake
            self.user_stakes.write((pool_id, address), stake);
            // grant the validator role
            self.accesscontrol._grant_role(VALIDATOR_ROLE, address);
            // add caller to validator list
            self.validators.append(address);
            Private::track_user_participation(ref self, address, pool_id);
            // emit event
            self.emit(UserStaked { pool_id, address, amount });
        }


        /// Returns whether a user has participated in a specific pool
        fn has_user_participated_in_pool(
            self: @ContractState, user: ContractAddress, pool_id: u256,
        ) -> bool {
            self.user_participated_pools.read((user, pool_id))
        }

        /// Returns the number of pools a user has participated in
        fn get_user_pool_count(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_pool_count.read(user)
        }

        fn get_user_pools(
            self: @ContractState, user: ContractAddress, status_filter: Option<Status>,
        ) -> Array<u256> {
            let mut result: Array<u256> = ArrayTrait::new();
            let pool_ids_count = self.user_pool_ids_count.read(user);

            // Pre-check if we have any pools to avoid gas costs on empty iterations
            if pool_ids_count == 0 {
                return result;
            }

            // Iterate through all pool IDs this user has participated in
            let mut i: u256 = 0;
            while i < pool_ids_count {
                let pool_id = self.user_pool_ids.read((user, i));

                // Only read from storage if needed
                if self.has_user_participated_in_pool(user, pool_id) {
                    // Apply status filter only if a filter is provided
                    if let Option::Some(status) = status_filter {
                        let pool = self.pools.read(pool_id);
                        if pool.exists && pool.status == status {
                            result.append(pool_id);
                        }
                    } else if self.retrieve_pool(pool_id) {
                        // No filter, just check if pool exists
                        result.append(pool_id);
                    }
                }
                i += 1;
            }

            result
        }


        /// Returns a list of active pools the user has participated in
        fn get_user_active_pools(self: @ContractState, user: ContractAddress) -> Array<u256> {
            self.get_user_pools(user, Option::Some(Status::Active))
        }

        /// Returns a list of locked pools the user has participated in
        fn get_user_locked_pools(self: @ContractState, user: ContractAddress) -> Array<u256> {
            self.get_user_pools(user, Option::Some(Status::Locked))
        }

        /// Returns a list of settled pools the user has participated in
        fn get_user_settled_pools(self: @ContractState, user: ContractAddress) -> Array<u256> {
            self.get_user_pools(user, Option::Some(Status::Settled))
        }


        // Check if a user has participated in a specific pool
        fn check_user_participated(
            self: @ContractState, user: ContractAddress, pool_id: u256,
        ) -> bool {
            self.user_pools.read((user, pool_id))
        }


        fn get_user_stake(
            self: @ContractState, pool_id: u256, address: ContractAddress,
        ) -> UserStake {
            self.user_stakes.read((pool_id, address))
        }
        fn get_pool_stakes(self: @ContractState, pool_id: u256) -> UserStake {
            self.pool_stakes.read(pool_id)
        }

        fn get_pool_vote(self: @ContractState, pool_id: u256) -> bool {
            self.pool_vote.read(pool_id)
        }
        fn get_pool_count(self: @ContractState) -> u256 {
            self.pool_count.read()
        }


        fn retrieve_pool(self: @ContractState, pool_id: u256) -> bool {
            let pool = self.pools.read(pool_id);
            pool.exists
        }

        fn get_creator_fee_percentage(self: @ContractState, pool_id: u256) -> u8 {
            let pool = self.pools.read(pool_id);
            pool.creatorFee
        }
        fn retrieve_validator_fee(self: @ContractState, pool_id: u256) -> u256 {
            self.validator_fee.read(pool_id)
        }

        fn get_validator_fee_percentage(self: @ContractState, pool_id: u256) -> u8 {
            10_u8
        }

        fn collect_pool_creation_fee(ref self: ContractState, creator: ContractAddress) {
            // Retrieve the STRK token contract
            let strk_token = IERC20Dispatcher { contract_address: self.token_addr.read() };

            // Check if the creator has sufficient balance for pool creation fee
            let creator_balance = strk_token.balance_of(creator);
            assert(creator_balance >= ONE_STRK, 'Insufficient STRK balance');

            // Check allowance to ensure the contract can transfer tokens
            let contract_address = get_contract_address();
            let allowed_amount = strk_token.allowance(creator, contract_address);
            assert(allowed_amount >= ONE_STRK, 'Insufficient allowance');

            // Transfer the pool creation fee from creator to the contract
            strk_token.transfer_from(creator, contract_address, ONE_STRK);
        }

        fn calculate_validator_fee(
            ref self: ContractState, pool_id: u256, total_amount: u256,
        ) -> u256 {
            // Validator fee is fixed at 10%
            let validator_fee_percentage = 5_u8;
            let validator_fee = (total_amount * validator_fee_percentage.into()) / 100_u256;

            self.validator_fee.write(pool_id, validator_fee);
            validator_fee
        }

        // Helper function to distribute validator fees evenly
        fn distribute_validator_fees(ref self: ContractState, pool_id: u256) {
            let total_validator_fee = self.validator_fee.read(pool_id);

            let validator_count = self.validators.len();

            // Convert validator_count to u256 for the division
            let validator_count_u256: u256 = validator_count.into();
            let fee_per_validator = total_validator_fee / validator_count_u256;

            let strk_token = IERC20Dispatcher { contract_address: self.token_addr.read() };

            // Distribute to each validator
            let mut i: u64 = 0;
            while i < validator_count {
                // Add debug info to trace the exact point of failure

                // Safe access to validator - check bounds first
                if i < self.validators.len() {
                    let validator_address = self.validators.at(i).read();
                    strk_token.transfer(validator_address, fee_per_validator);
                } else {}
                i += 1;
            }
            // Reset the validator fee for this pool after distribution
            self.validator_fee.write(pool_id, 0);
        }

        fn add_validators(
            ref self: ContractState,
            validator1: ContractAddress,
            validator2: ContractAddress,
            validator3: ContractAddress,
            validator4: ContractAddress,
        ) -> Array<ContractAddress> {
            self.validators.push(validator1);
            self.validators.push(validator2);
            self.validators.push(validator3);
            self.validators.push(validator4);

            let mut validators = array![];
            // Append each validator to the array
            validators.append(validator1);
            validators.append(validator2);
            validators.append(validator3);
            validators.append(validator4);
            validators
        }


        fn get_pool_validators(
            self: @ContractState, pool_id: u256,
        ) -> (ContractAddress, ContractAddress) {
            self.pool_validator_assignments.read(pool_id)
        }

        fn assign_random_validators(ref self: ContractState, pool_id: u256) {
            // Get the number of available validators
            let validator_count = self.validators.len();

            // If we have fewer than 2 validators, handle the edge case
            if validator_count == 0 {
                // No validators available, don't assign any
                return;
            } else if validator_count == 1 {
                // Only one validator available, assign the same validator twice
                let validator = self.validators.at(0).read();
                self.assign_validators(pool_id, validator, validator);
                return;
            }

            // Generate two random indices for validator selection
            // Use the pool_id and timestamp to create randomness
            let timestamp = get_block_timestamp();
            let seed1 = pool_id + timestamp.into();
            let seed2 = pool_id + (timestamp * 2).into();

            // Use modulo to get indices within the range of available validators
            let index1 = seed1 % validator_count.into();
            // Ensure the second index is different from the first
            let mut index2 = seed2 % validator_count.into();
            if index1 == index2 && validator_count > 1 {
                index2 = (index2 + 1) % validator_count.into();
            }

            // Get the selected validators
            let validator1 = self.validators.at(index1.try_into().unwrap()).read();
            let validator2 = self.validators.at(index2.try_into().unwrap()).read();

            // Assign the selected validators to the pool
            self.assign_validators(pool_id, validator1, validator2);
        }

        fn assign_validators(
            ref self: ContractState,
            pool_id: u256,
            validator1: ContractAddress,
            validator2: ContractAddress,
        ) {
            self.pool_validator_assignments.write(pool_id, (validator1, validator2));
            let timestamp = get_block_timestamp();
            self
                .emit(
                    Event::ValidatorsAssigned(
                        ValidatorsAssigned { pool_id, validator1, validator2, timestamp },
                    ),
                );
        }

        // Get active pools
        fn get_active_pools(self: @ContractState) -> Array<PoolDetails> {
            Private::get_pools_by_status(self, Status::Active)
        }

        // Get locked pools
        fn get_locked_pools(self: @ContractState) -> Array<PoolDetails> {
            Private::get_pools_by_status(self, Status::Locked)
        }

        // Get settled pools
        fn get_settled_pools(self: @ContractState) -> Array<PoolDetails> {
            Private::get_pools_by_status(self, Status::Settled)
        }

        // Get closed pools
        fn get_closed_pools(self: @ContractState) -> Array<PoolDetails> {
            Private::get_pools_by_status(self, Status::Closed)
        }
    }

    #[generate_trait]
    impl Private of PrivateTrait {
        /// Generates a unique pool ID using deterministic number generation
        fn generate_unique_pool_id(ref self: ContractState) -> u256 {
            let pool_id = self.generate_deterministic_number();
            assert(!self.retrieve_pool(pool_id), "Pool ID already exists");
            pool_id
        }

        /// Creates pool details structure from input parameters
        fn create_pool_details(
            ref self: ContractState,
            poolName: felt252,
            poolType: Pool,
            poolDescription: ByteArray,
            poolImage: ByteArray,
            poolEventSourceUrl: ByteArray,
            poolStartTime: u64,
            poolLockTime: u64,
            poolEndTime: u64,
            option1: felt252,
            option2: felt252,
            minBetAmount: u256,
            maxBetAmount: u256,
            creatorFee: u8,
            isPrivate: bool,
            category: Category,
        ) ->