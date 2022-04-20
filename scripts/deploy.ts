// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";
import * as fs from "fs";

/* tslint:disable */
/* eslint-disable */

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy

  // proposal
  const proposalFactory = await ethers.getContractFactory("Proposal");
  const proposalContract = await proposalFactory.deploy();

  await proposalContract.deployed();

  const proposalCode = await ethers.provider.getCode(proposalContract.address);
  console.log("proposalCode ", proposalCode);

  fs.writeFileSync("./bin/proposal_deployed_code", proposalCode);


  // punish
  const punishFactory = await ethers.getContractFactory("Punish");
  const punishContract = await punishFactory.deploy();

  await proposalContract.deployed();

  const punishCode = await ethers.provider.getCode(punishContract.address);
  console.log("punishCode ", punishCode);

  fs.writeFileSync("./bin/punish_deployed_code", punishCode);


  // reserve pool
  const reservePoolFactory = await ethers.getContractFactory("ReservePool");
  const reservePoolContract = await reservePoolFactory.deploy();

  await reservePoolContract.deployed();

  const reservePoolCode = await ethers.provider.getCode(reservePoolContract.address);
  console.log("reservePoolCode ", reservePoolCode);

  fs.writeFileSync("./bin/reservePool_deployed_code", reservePoolCode);

  // validators
  const validatorsFactory = await ethers.getContractFactory("Validators");
  const validatorsContract = await validatorsFactory.deploy();

  await validatorsContract.deployed();

  const validatorsCode = await ethers.provider.getCode(validatorsContract.address);
  console.log("validatorsCode ", validatorsCode);

  fs.writeFileSync("./bin/validators_deployed_code", validatorsCode);

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
