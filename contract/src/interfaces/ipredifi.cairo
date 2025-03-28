use starknet::ContractAddress;
use crate::base::types::{Category, Pool, PoolDetails, PoolOdds, UserStake};
#[starknet::interface]
pub trait IPredifi<TContractState> {
    // Pool Creation and Management
    fn create_pool(
        ref self: TContractState,
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
    ) -> u256;

    fn pool_count(self: @TContractState) -> u256;
    fn pool_odds(self: @TContractState, pool_id: u256) -> PoolOdds;
    fn get_pool(self: @TContractState, pool_id: u256) -> PoolDetails;
    fn vote(ref self: TContractState, pool_id: u256, option: felt252, amount: u256);
    fn get_user_stake(self: @TContractState, pool_id: u256, address: ContractAddress) -> UserStake;
    fn get_pool_stakes(self: @TContractState, pool_id: u256) -> UserStake;
    fn get_pool_vote(self: @TContractState, pool_id: u256) -> bool;
    fn get_pool_count(self: @TContractState) -> u256;
    fn retrieve_pool(self: @TContractState, pool_id: u256) -> bool;
    fn register_validator(ref self: TContractState, stake: u256);
    fn verify_validator_assignment(
        self: @TContractState, pool_id: u256, validator: ContractAddress,
    ) -> bool;
    fn get_validators_count(self: @TContractState) -> u256;
}
