use starknet::ContractAddress;

#[starknet::interface]
trait VoteTrait<TContractState> {
    fn add_proposal(ref self: TContractState, proposal_name: felt252);
    fn register_voter(ref self: TContractState, voter_address: ContractAddress);
    fn get_proposal(self: @TContractState, proposal_id: u8) -> vote::Proposal;
    fn get_proposal_vote(self: @TContractState, proposal_id: u8) -> u32;
    fn delegate_vote(ref self: TContractState, to: ContractAddress);
    fn vote(ref self: TContractState, proposal_id: u8);
    fn winning_proposal(self: @TContractState) -> u8;
    fn winner_name(self: @TContractState) -> felt252;
}

#[starknet::contract]
pub mod vote {
    use starknet::{ContractAddress, get_caller_address, contract_address_const};

    #[storage]
    struct Storage {
        chairperson: ContractAddress,
        proposals: LegacyMap<u8, Proposal>,
        proposal_id: u8,
        voters: LegacyMap<ContractAddress, Voter>,
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct Voter {
        has_voted: bool,
        is_registered: bool,
        weight: u32,
        delegate: ContractAddress,
    }

    #[derive(Drop, Serde, starknet::Store)]
    pub struct Proposal {
        id: u8,
        name: felt252,
        vote_count: u32,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        VoterRegistered: VoterRegistered,
        ProposalAdded: ProposalAdded,
        Voted: Voted,
        Delegate: Delegate,
    }

    #[derive(Drop, starknet::Event)]
    struct VoterRegistered {
        #[key]
        voter: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct ProposalAdded {
        #[key]
        proposal_id: u8,
        proposal_name: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct Voted {
        #[key]
        voter: ContractAddress,
        proposal_id: u8,
    }

    #[derive(Drop, starknet::Event)]
    struct Delegate {
        #[key]
        voter: ContractAddress,
        to: ContractAddress,
    }

    #[constructor]
    fn constructor(ref self: ContractState, chairperson: ContractAddress) {
        self.chairperson.write(chairperson);
    }

    #[abi(embed_v0)]
    impl VoteImpl of super::VoteTrait<ContractState> {
        fn add_proposal(ref self: ContractState, proposal_name: felt252) {
            self._only_owner();

            let proposal_id = self.proposal_id.read();
            let current_proposal_id = proposal_id + 1_u8;

            let proposal_info = Proposal {
                id: current_proposal_id,
                name: proposal_name,
                vote_count: 0,
            };
            self.proposals.write(proposal_id, proposal_info);

            self.proposal_id.write(current_proposal_id);
            self.emit(ProposalAdded {
                proposal_id: current_proposal_id,
                proposal_name,
            });
        }

        fn register_voter(ref self: ContractState, voter_address: ContractAddress) {
            self._only_owner();
            self._check_not_registered(voter_address);

            let voter_info = Voter {
                has_voted: false,
                is_registered: true,
                weight: 1,
                delegate: self.zero_address(),
            };
            self.voters.write(voter_address, voter_info);

            self.emit(VoterRegistered {
                voter: voter_address,
            });
        }

        fn get_proposal(self: @ContractState, proposal_id: u8) -> Proposal {
            self.proposals.read(proposal_id)
        }

        fn get_proposal_vote(self: @ContractState, proposal_id: u8) -> u32 {
            self.proposals.read(proposal_id).vote_count
        }

        fn delegate_vote(ref self: ContractState, to: ContractAddress) {
            let caller = get_caller_address();

            assert!(to != caller, "DELEGATE_LOOP");
            self._check_is_registered(caller);
            self._check_vote_status(caller);
            self._check_is_registered(to);
            self._check_vote_status(to);

            let caller = get_caller_address();
            let voter = self.voters.read(caller);
            let voter_weight = voter.weight;
            let reciever = self.voters.read(to);
            let original_weight = reciever.weight;
            let current_weight = original_weight + voter_weight;

            let updated_caller_info = Voter {
                has_voted: true,
                is_registered: true,
                weight: 0,
                delegate: to,
            };
            self.voters.write(caller, updated_caller_info);

            let updated_voter_info = Voter {
                has_voted: false,
                is_registered: true,
                weight: current_weight,
                delegate: self.zero_address(),
            };
            self.voters.write(to, updated_voter_info);

            self.emit(Delegate {
                voter: caller,
                to,
            });
        }

        fn vote(ref self: ContractState, proposal_id: u8) {
            let caller = get_caller_address();

            self._check_proposal_exists(proposal_id);
            self._check_is_registered(caller);
            self._check_vote_status(caller);
            self.can_vote(caller);

            let voter = self.voters.read(caller);
            let voter_weight = voter.weight;
            let proposal = self.proposals.read(proposal_id);
            let current_vote_count = proposal.vote_count + voter_weight;

            let updated_proposal_info = Proposal {
                id: proposal.id,
                name: proposal.name,
                vote_count: current_vote_count,
            };
            self.proposals.write(proposal_id, updated_proposal_info);

            let updated_voter_info = Voter {
                has_voted: true,
                is_registered: true,
                weight: 0,
                delegate: self.zero_address(),
            };
            self.voters.write(caller, updated_voter_info);

            self.emit(Voted {
                voter: caller,
                proposal_id,
            });
        }

        fn winning_proposal(self: @ContractState) -> u8 {
            let mut winning_vote_count: u32 = 0_u32;
            let mut winning_proposal_id: u8 = 1_u8;
            let num_of_proposals = self.proposal_id.read();

            while winning_proposal_id < num_of_proposals {
                let proposal = self.proposals.read(winning_proposal_id);
                if proposal.vote_count > winning_vote_count {
                    winning_vote_count = proposal.vote_count;
                    winning_proposal_id = proposal.id;
                }
                winning_proposal_id += 1;
            };

            winning_proposal_id
        }

        fn winner_name(self: @ContractState) -> felt252 {
            let winning_proposal_id = self.winning_proposal();
            let winning_proposal = self.proposals.read(winning_proposal_id);

            winning_proposal.name
        }
    }

    #[generate_trait]
    impl ChairpersonImpl of ChairpersonTrait {
        fn _only_owner(ref self: ContractState) {
            let caller = get_caller_address();
            let chairperson = self.chairperson.read();
            assert!(caller == chairperson, "NOT_CHAIRPERSON");
        }

        fn _not_owner(ref self: ContractState) {
            let caller = get_caller_address();
            let chairperson = self.chairperson.read();
            assert!(caller != chairperson, "IS_CHAIRPERSON");
        }
    }

    #[generate_trait]
    impl VoterImpl of VoterTrait {
        fn _check_not_registered(ref self: ContractState, voter: ContractAddress) {
            let is_registered = self.voters.read(voter).is_registered;
            assert!(!is_registered, "ALREADY_REGISTERED");
        }

        fn _check_is_registered(ref self: ContractState, voter: ContractAddress) {
            let is_registered = self.voters.read(voter).is_registered;
            assert!(is_registered, "NOT_REGISTERED");
        }

        fn _check_vote_status(ref self: ContractState, voter: ContractAddress) {
            let has_voted = self.voters.read(voter).has_voted;
            assert!(!has_voted, "ALREADY_VOTED");
        }

        fn can_vote(ref self: ContractState, voter: ContractAddress) {
            let caller_weight = self.voters.read(voter).weight;
            assert!(caller_weight > 0, "NO_WEIGHT");
        }
    }

    #[generate_trait]
    impl ZeroAddressImpl of ZeroAddressTrait {
        fn zero_address(self: @ContractState) -> ContractAddress {
            contract_address_const::<0>()
        }
    }

    #[generate_trait]
    impl ProposalImpl of ProposalTrait {
        fn _check_proposal_exists(ref self: ContractState, proposal_id: u8) {
            let num_of_proposals = self.proposal_id.read();
            assert!(proposal_id <= num_of_proposals, "PROPOSAL_NOT_FOUND");
        }
    }
}