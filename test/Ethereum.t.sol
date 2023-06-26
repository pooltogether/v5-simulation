// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
// import { UFixed32x4 } from "v5-liquidator/libraries/FixedMathLib.sol";
import { UD2x18 } from "prb-math/UD2x18.sol";
import { SD1x18 } from "prb-math/SD1x18.sol";
import { SD59x18, toSD59x18, convert, wrap } from "prb-math/SD59x18.sol";
import { TwabLib } from "v5-twab-controller/libraries/TwabLib.sol";

import {
    Environment,
    PrizePoolConfig,
    LiquidatorConfig,
    ClaimerConfig,
    GasConfig
} from "src/Environment.sol";

import { ClaimerAgent } from "src/ClaimerAgent.sol";
import { DrawAgent } from "src/DrawAgent.sol";
import { LiquidatorAgent } from "src/LiquidatorAgent.sol";
import { ValuesOverTime } from "src/ValuesOverTime.sol";

contract EthereumTest is Test {

    string runStatsOut = string.concat(vm.projectRoot(), "/data/simulation.csv");

    uint32 drawPeriodSeconds = 1 days;
    uint16 grandPrizePeriodDraws = 365;

    uint duration = 4 days + 0.5 days;
    uint timeStep = 5 minutes;
    uint startTime;

    uint totalValueLocked = 100_000_000e18;
    uint apr = 0.05e18;
    uint numUsers = 1;

    PrizePoolConfig public prizePoolConfig;
    LiquidatorConfig public liquidatorConfig;
    ClaimerConfig public claimerConfig;
    GasConfig public gasConfig;
    Environment public env;

    ClaimerAgent public claimerAgent;
    LiquidatorAgent public liquidatorAgent;
    DrawAgent public drawAgent;

    ValuesOverTime public exchangeRateUnderlyingToPoolToken;

    function setUp() public {
        startTime = block.timestamp + 400 days;
        vm.warp(startTime);

        exchangeRateUnderlyingToPoolToken = new ValuesOverTime();
        exchangeRateUnderlyingToPoolToken.add(startTime, wrap(10e18));

        prizePoolConfig = PrizePoolConfig({
            grandPrizePeriodDraws: grandPrizePeriodDraws,
            drawPeriodSeconds: drawPeriodSeconds,
            firstDrawStartsAt: uint64(startTime),
            numberOfTiers: 3,
            tierShares: 100,
            canaryShares: 30,
            reserveShares: 20,
            claimExpansionThreshold: UD2x18.wrap(0.8e18),
            smoothing: SD1x18.wrap(0.3e18)
        });

        liquidatorConfig = LiquidatorConfig({
            initialPrice: convert(0.1e18),
            decayConstant: SD59x18.wrap(0.0003e18)
        });

        claimerConfig = ClaimerConfig({
            minimumFee: 0.1e18,
            maximumFee: 1000e18,
            timeToReachMaxFee: drawPeriodSeconds/7,
            maxFeePortionOfPrize: UD2x18.wrap(0.2e18)
        });

        gasConfig = GasConfig({
            gasPriceInPrizeTokens: 700 gwei,
            gasUsagePerClaim: 150_000,
            gasUsagePerLiquidation: 500_000,
            gasUsagePerStartDraw: 152_473,
            gasUsagePerCompleteDraw:  66_810,
            gasUsagePerDispatchDraw:  250_000
        });

        env = new Environment(
            prizePoolConfig,
            liquidatorConfig,
            claimerConfig,
            gasConfig
        );

        claimerAgent = new ClaimerAgent(env);
        liquidatorAgent = new LiquidatorAgent(env);
        drawAgent = new DrawAgent(env);
    }

    function testEthereum() public noGasMetering {
        vm.warp(startTime);

        env.addUsers(numUsers, totalValueLocked / numUsers);
        env.setApr(apr);

        for (uint i = startTime; i < startTime + duration; i += timeStep) {
            vm.warp(i);
            uint availableYield = env.vault().liquidatableBalanceOf(address(env.vault()));
            uint availableVaultShares = env.pair().maxAmountOut();
            uint requiredPrizeTokens = env.pair().computeExactAmountIn(availableVaultShares);
            uint prizePoolReserve = env.prizePool().reserve();

            env.mintYield();
            claimerAgent.check();
            liquidatorAgent.check(exchangeRateUnderlyingToPoolToken.get(block.timestamp));
            drawAgent.check();
        }

        printDraws();
        printMissedPrizes();
        printTotalNormalPrizes();
        printTotalCanaryPrizes();
        printTotalClaimFees();
        printPrizeSummary();
        printFinalPrizes();
    }

    function printDraws() public {
        uint totalDraws = duration / drawPeriodSeconds;
        uint missedDraws = (totalDraws) - drawAgent.drawCount();
        console2.log("");
        console2.log("Expected draws", totalDraws);
        console2.log("Actual draws", drawAgent.drawCount());
        console2.log("Missed Draws", missedDraws);
    }

    function printMissedPrizes() public {
        uint lastDrawId = env.prizePool().getLastCompletedDrawId();
        for (uint32 drawId = 0; drawId <= lastDrawId; drawId++) {
            uint numTiers = claimerAgent.drawNumberOfTiers(drawId);
            for (uint8 tier = 0; tier < numTiers; tier++) {
                uint256 prizeCount = claimerAgent.drawNormalTierComputedPrizeCounts(drawId, tier);
                uint256 claimCount = claimerAgent.drawNormalTierClaimedPrizeCounts(drawId, tier);
                if (claimCount < prizeCount) {
                    console2.log("!!!!! MISSED PRIZES draw, tier, count", drawId, tier, prizeCount - claimCount);
                }
            }
        }
    }

    function printTotalNormalPrizes() public {
        uint normalComputed = claimerAgent.totalNormalPrizesComputed();
        uint normalClaimed = claimerAgent.totalNormalPrizesClaimed();
        console2.log("");
        console2.log("Number of normal prizes", normalComputed);
        console2.log("Number of prizes claimed", normalClaimed);
        console2.log("Missed normal prizes", normalComputed - normalClaimed);
    }

    function printTotalCanaryPrizes() public {
        uint canaryComputed = claimerAgent.totalCanaryPrizesComputed();
        uint canaryClaimed = claimerAgent.totalCanaryPrizesClaimed();
        console2.log("");
        console2.log("Number of canary prizes", canaryComputed);
        console2.log("Number of canary prizes claimed", canaryClaimed);
        console2.log("Missed canary prizes", canaryComputed - canaryClaimed);        
    }

    function printTotalClaimFees() public {
        uint totalClaims = (claimerAgent.totalNormalPrizesClaimed() + claimerAgent.totalCanaryPrizesClaimed());
        uint averageFeePerClaim;
        if (totalClaims != 0) {
            averageFeePerClaim = claimerAgent.totalFees() / totalClaims;
        }
        console2.log("");
        console2.log("Average fee per claim (cents): ", averageFeePerClaim / 1e16);
    }

    function printPrizeSummary() public {
        uint8 maxTiers;
        uint lastDrawId = env.prizePool().getLastCompletedDrawId();
        for (uint32 drawId = 0; drawId <= lastDrawId; drawId++) {
            uint8 numTiers = claimerAgent.drawNumberOfTiers(drawId);
            if (numTiers > maxTiers) {
                maxTiers = numTiers;
            }
        }

        uint256[] memory tierPrizeCounts = new uint256[](maxTiers);
        for (uint32 drawId = 0; drawId <= lastDrawId; drawId++) {
            uint8 numTiers = claimerAgent.drawNumberOfTiers(drawId);
            if (numTiers > maxTiers) {
                maxTiers = numTiers;
            }
            for (uint8 tier = 0; tier < numTiers; tier++) {
                tierPrizeCounts[tier] += claimerAgent.drawNormalTierClaimedPrizeCounts(drawId, tier);
            }
        }

        for (uint8 tier = 0; tier < tierPrizeCounts.length; tier++) {
            console2.log("Tier", tier, "prizes", tierPrizeCounts[tier]);
        }
    }


    function printFinalPrizes() public {
        uint8 numTiers = env.prizePool().numberOfTiers();
        for (uint8 tier = 0; tier < numTiers; tier++) {
            console2.log("Final prize size for tier", tier, "is", env.prizePool().getTierPrizeSize(tier) / 1e18);
        }
    }

}
