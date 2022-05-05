/* tslint:disable */
/* eslint-disable */

// - setFeeSharesOfValidator  

import { expect } from "chai";
import { ethers } from "hardhat";
import {Validators} from "../typechain";
import { setBalance } from "./helpers";

type SignerWithAddress = Awaited<ReturnType<typeof ethers["getSigner"]>>;


describe("manager set fee shares of validator's pool", function () {
// the validators contract
        let validatorContract: Validators;
        let deployer: SignerWithAddress;
        let admin: SignerWithAddress;
        let miner: SignerWithAddress;
        let initialValidators: SignerWithAddress[];
        const MIN_SELF_BALLOTS_IN_KCS = ethers.constants.WeiPerEther.mul(10000); // minimum Self Ballots denominated in KCS 
        const MIN_SELF_BALLOTS = MIN_SELF_BALLOTS_IN_KCS.div(ethers.constants.WeiPerEther);

        beforeEach(async () => {

            const signers = await ethers.getSigners();
            let others:SignerWithAddress[];
            [deployer, admin, miner,...others] = signers;

            validatorContract = await (await ethers.getContractFactory("Validators", deployer)).deploy()

            initialValidators = others.slice(0, 7); // the first 7 candidate as the init validators

            // initial KCS in contract 
            await setBalance(validatorContract.address,MIN_SELF_BALLOTS_IN_KCS.mul(initialValidators.length));
        

            // initialize for the first time
            await validatorContract.initialize(
                initialValidators.map(v => v.address),
                initialValidators.map(v => v.address),
                initialValidators.map(v => 2000), // 20% feeShare
                admin.address,
                validatorContract.address,
                ethers.constants.AddressZero,
                ethers.constants.AddressZero,
                ethers.constants.AddressZero,100);

        });

        it("test set fee shares", async function () {

        });

});