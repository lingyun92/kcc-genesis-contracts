/* tslint:disable */
/* eslint-disable */



import {
    Validators,
    PunishMockForValidator,
    CallDistributeBlockRewardMultipleTimes,
    ReservePoolMockForValidators
} from "../typechain";
import {ethers} from "hardhat";
import {mineBlocks, setBalance, setCoinbase} from "./helpers";
import {expect} from "chai";
import {BigNumber} from "ethers";

type SignerWithAddress = Awaited<ReturnType<typeof ethers["getSigner"]>>;

describe("validators: test punish", function () {

    // the validators contract
    let validatorContract: Validators;
    let reservePoolMock : ReservePoolMockForValidators;
    let deployer: SignerWithAddress;
    let admin: SignerWithAddress;
    let miner: SignerWithAddress;
    let punishContract: SignerWithAddress;
    let initialValidators: SignerWithAddress[];
    let validatorSet: string[];

    // constants
    const REDEEM_LOCK_DURATION = 3 * 24 * 60 * 60; // 3 days
    const FEE_SET_LOCKING_DURATION = 1 * 24 * 60 * 60; // 1 day
    const INITIAL_FEE_SHARE = 2000; // initial commission fee rate for validator （20%）
    const MIN_SELF_BALLOTS_IN_KCS = ethers.constants.WeiPerEther.mul(10000); // minimum Self Ballots denominated in KCS
    const MIN_SELF_BALLOTS = MIN_SELF_BALLOTS_IN_KCS.div(ethers.constants.WeiPerEther);

    beforeEach(async () => {

        const signers = await ethers.getSigners();
        let others:SignerWithAddress[];
        [deployer, admin, miner, punishContract,...others] = signers;

        validatorContract = await (await ethers.getContractFactory("Validators", deployer)).deploy();
        reservePoolMock = await (await ethers.getContractFactory("ReservePoolMockForValidators", deployer)).deploy();


        const blockReward = ethers.constants.WeiPerEther.mul(7);
        await reservePoolMock.setBlockReward(blockReward);


        initialValidators = others.slice(0, 7); // the first 7 candidate as the init validators

    
        // initial KCS in contract 
        await setBalance(validatorContract.address, MIN_SELF_BALLOTS_IN_KCS.mul(initialValidators.length));
        await setBalance(reservePoolMock.address, ethers.constants.WeiPerEther.mul(7));


        validatorSet = initialValidators.map(v => v.address)
        // initialize for the first time
        await validatorContract.initialize(
            validatorSet,
            validatorSet,
            initialValidators.map(v => 2000), // 20% feeShare
            admin.address,
            validatorContract.address,
            punishContract.address, // use an EOA to fake the punish contract 
            ethers.constants.AddressZero,
            reservePoolMock.address,100);


    });

    // it("only punish reward", async function () {
    //
    //
    //     // mining a block and distribute this block's reward
    //     let times = 3
    //     for (let i = 0; i < times; i++) {
    //         await setCoinbase(miner.address);
    //         await validatorContract.connect(miner).distributeBlockReward();
    //     }
    //
    //     let pendingFee = await validatorContract.getPoolpendingFee(validatorSet[0])
    //
    //
    //
    //     //await validatorContract.connect(validatorSet[0]).claimSelfBallotsReward(validatorSet[0])
    //
    //
    //     //let debate = await validatorContract.getPoolSelfBallotsRewardsDebt(validatorSet[0]);
    //
    //     console.log(pendingFee);
    //     await validatorContract.connect(punishContract).punish(validatorSet[0], false);
    //     let maxPunishmentAmount = await validatorContract.maxPunishmentAmount();
    //     console.log(pendingFee);
    //     // console.log(maxPunishmentAmount);
    //     // console.log(await validatorContract.getPoolpendingFee(validatorSet[0]));
    //     expect(await validatorContract.getPoolpendingFee(validatorSet[0])).to.equal(pendingFee.add(maxPunishmentAmount));
    //
    //     console.log(await validatorContract.getPoolSelfBallotsRewardsDebt(validatorSet[0]));
    //     //expect(await validatorContract.getPoolSelfBallotsRewardsDebt(validatorSet[0]), "self ballot debate ").to.greaterThan(BigNumber.from(debate));
    //
    //
    //
    // });

    it("punish reward and remove from top active validator set", async function () {
        await validatorContract.connect(punishContract).punish(validatorSet[0], true);

        expect(await validatorContract.getTopValidators()).not.contains(validatorSet[0]);
        expect(await validatorContract.getTopValidators()).to.deep.equal(validatorSet.slice(1));
    });


    it("punishment", async function () {
        //const MAX_PUNISHMENT_AMOUNT = ethers.constants.WeiPerEther.mul(100); // maximum punishment amount

        //const reserveAmount = await ethers.provider.getBalance(reservePoolMock.address);
        // reservePool setup
        // block reward is 5 kcs
        const blockReward = ethers.constants.WeiPerEther.mul(7);
        await reservePoolMock.setBlockReward(blockReward);
        await setCoinbase(deployer.address);

        // number of active validators
        // block reward will be distributed to these validators
        const numOfActiveValidators = initialValidators.length;


        await validatorContract.distributeBlockReward();

        expect(await ethers.provider.getBalance(reservePoolMock.address)).to.equal(BigNumber.from(0));

        // the selfBallots of each validator
        const selfBallotsPerPool = MIN_SELF_BALLOTS;

        for(let i =0; i < numOfActiveValidators; ++i){
            const val = initialValidators[i].address;
            expect(await validatorContract.getPoolSelfBallots(val))
                .to.be.equals(selfBallotsPerPool);
            expect(await validatorContract.getPoolsuppliedBallot(val))
                .to.be.equal(selfBallotsPerPool)
        }

        // we have 7 pools with the same ballots

        const totalBallots = selfBallotsPerPool.mul(numOfActiveValidators);
        // rewards distributed to each ballot
        const rewardPerBallot = blockReward.div(totalBallots);
        // rewards per pool
        const rewardsPerPool = rewardPerBallot.mul(selfBallotsPerPool);
        // the commission fee paid to pool's validator
        const feeRewardPerPool = rewardsPerPool.mul(INITIAL_FEE_SHARE).div(10000);
        // the accRewardPerShare of each pool
        const accRewardPerSharePerPool = rewardsPerPool.sub(feeRewardPerPool).mul(1e12).div(MIN_SELF_BALLOTS);

        let fee = BigNumber.from(0);
        for(let i =0; i < numOfActiveValidators; ++i) {
            const val = initialValidators[i].address;

            let f = await validatorContract.getPoolpendingFee(val);
            fee = fee.add(f);
            expect(await validatorContract.getPoolpendingFee(val),
                "check pending commission fee of each pool")
                .to.be.equal(feeRewardPerPool);

            expect(await validatorContract.getPoolaccRewardPerShare(val),
                "check accRewardPerShare of each pool ")
                .to.be.equal(accRewardPerSharePerPool);

        }


        // the roundoff error in distributing to each pool will
        // be accummulated to rewardsLeft

        const rewardsLeft = blockReward.sub(rewardsPerPool.mul(numOfActiveValidators));


        expect(await validatorContract.rewardsLeft(),
            "check rewardLeft (roundoff error accumulated)")
            .to.be.equal(rewardsLeft);


        expect(await ethers.provider.getBalance(validatorContract.address)).to.equal(MIN_SELF_BALLOTS_IN_KCS.mul(7).add(blockReward));



        for(let i =0; i < numOfActiveValidators; ++i) {
            const val = initialValidators[i].address;
            await validatorContract.connect(punishContract).punish(val, false);
        }


        expect(await ethers.provider.getBalance(validatorContract.address)).to.equal(MIN_SELF_BALLOTS_IN_KCS.mul(7).add(blockReward).sub(blockReward));
        expect(await ethers.provider.getBalance(reservePoolMock.address)).to.equal(blockReward);


        // for(let i =0; i < numOfActiveValidators; ++i) {
        //     const val = initialValidators[i].address;
        //
        //     expect(await validatorContract.getPoolpendingFee(val),
        //         "check pending commission fee of each pool")
        //         .to.be.equal(feeRewardPerPool);
        //
        //     expect(await validatorContract.getPoolaccRewardPerShare(val),
        //         "check accRewardPerShare of each pool ")
        //         .to.be.equal(accRewardPerSharePerPool);
        //
        // }

    });

});