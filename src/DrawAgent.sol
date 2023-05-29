pragma solidity 0.8.17;

import "forge-std/console2.sol";

import { Environment, GasConfig } from "src/Environment.sol";

contract DrawAgent {

    Environment public env;

    uint public drawCount;

    constructor (Environment _env) {
        env = _env;
    }

    function check() public {

        GasConfig memory gasConfig = env.gasConfig();
        uint cost = gasConfig.gasUsagePerCompleteDraw * gasConfig.gasPriceInPrizeTokens;
        uint minimum = cost + (cost / 10); // require 10% profit
        if (env.prizePool().hasNextDrawFinished()) {
            if (env.prizePool().getNextDrawId() == 1) {
                console2.log("DrawAgent Draw ", uint(1));
                env.prizePool().completeAndStartNextDraw(uint256(keccak256(abi.encodePacked(block.timestamp))));
                drawCount++;
            } else if (env.prizePool().reserve() >= minimum) {
                console2.log("DrawAgent Draw ", env.prizePool().getNextDrawId());
                env.prizePool().completeAndStartNextDraw(uint256(keccak256(abi.encodePacked(block.timestamp))));
                env.prizePool().withdrawReserve(address(this), uint104(minimum));
                drawCount++;
            } else {
                // console2.log("Insufficient reserve to draw");
            }
        }
    }
}