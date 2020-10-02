pragma solidity >=0.5.15;
pragma experimental ABIEncoderV2;

import "openzeppelin-eth/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-eth/contracts/ownership/Ownable.sol";
import "./interface/IDollars.sol";
import "./interface/IRebaser.sol";
import './interface/IUniswapV2Pair.sol';
import "./lib/UInt256Lib.sol";
import "./lib/SafeMathInt.sol";

interface IDecentralizedOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}

contract DollarReserve is Ownable {
    address public reserveToken;
    using SafeMath for uint256;

    address public gov;

    address public pendingGov;

    address public rebaser;

    uint256 private constant DECIMALS = 18;

    address public dollarAddress;
    address public uniswap_reserve_pair;

    bool public isToken0;

    struct UniVars {
      uint256 dollarsToUni;
      uint256 amountFromReserves;
      uint256 mintToReserves;
    }

    event NewPendingGov(address oldPendingGov, address newPendingGov);
    event NewGov(address oldGov, address newGov);
    event NewRebaser(address oldRebaser, address newRebaser);
    event NewReserveContract(address oldReserveContract, address newReserveContract);
    event TreasuryIncreased(uint256 reservesAdded, uint256 fedCashSold, uint256 fedCashFromReserves, uint256 fedCashToReserves);

    modifier onlyGov() {
        require(msg.sender == gov);
        _;
    }

    modifier onlyRebaser() {
        require(msg.sender == rebaser);
        _;
    }

    event BuyAmount(uint256 amount, uint256 amountIn, uint256 reserve0, uint256 reserve1);
    event LogReserves(uint256 r1, uint256 r2);
    event LogAmount(uint256 r3);

    function initialize(
        address owner_,
        address reserveToken_,
        address dollarAddress_,
        address rebaser_,
        address uniswap_factory_
    )
        public
        initializer
    {
        Ownable.initialize(owner_);
        reserveToken = reserveToken_;
        dollarAddress = dollarAddress_;

        (address token0, address token1) = sortTokens(dollarAddress_, reserveToken_);
        if (token0 == dollarAddress_) {
            isToken0 = true;
        } else {
            isToken0 = false;
        }

        uniswap_reserve_pair = pairFor(uniswap_factory_, token0, token1);

        rebaser = rebaser_;
        IDollars(dollarAddress).approve(rebaser_, uint256(-1));

        gov = msg.sender;
    }

    function _setReserveToken(address reserveToken_, address uniswap_factory_)
        external
        onlyGov
    {
        reserveToken = reserveToken_;

        (address token0, address token1) = sortTokens(dollarAddress, reserveToken_);
        if (token0 == dollarAddress) {
            isToken0 = true;
        } else {
            isToken0 = false;
        }

        uniswap_reserve_pair = pairFor(uniswap_factory_, token0, token1);
    }

    function _setRebaser(address rebaser_)
        external
        onlyGov
    {
        address oldRebaser = rebaser;
        IDollars(dollarAddress).decreaseAllowance(oldRebaser, uint256(-1));
        rebaser = rebaser_;
        IDollars(dollarAddress).approve(rebaser_, uint256(-1));
        emit NewRebaser(oldRebaser, rebaser_);
    }

    /** @notice sets the pendingGov
     * @param pendingGov_ The address of the gov contract to use for authentication.
     */
    function _setPendingGov(address pendingGov_)
        external
        onlyGov
    {
        address oldPendingGov = pendingGov;
        pendingGov = pendingGov_;
        emit NewPendingGov(oldPendingGov, pendingGov_);
    }

    function uniswapMaxSlippage(
        uint256 token0,
        uint256 token1,
        uint256 offPegPerc,
        uint256 maxSlippageFactor
    )
      internal
      view
      returns (uint256)
    {
        if (isToken0) {
            if (offPegPerc >= 10 ** 8) {
                return token0.mul(maxSlippageFactor).div(10 ** 9);
            } else {
                return token0.mul(offPegPerc).div(3 * 10 ** 9);
            }
        } else {
            if (offPegPerc >= 10 ** 8) {
                return token1.mul(maxSlippageFactor).div(10 ** 9);
            } else {
                return token1.mul(offPegPerc).div(3 * 10 ** 9);
            }   
        }
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes memory data
    )
        public
    {
        // enforce that it is coming from uniswap
        require(msg.sender == uniswap_reserve_pair, "bad msg.sender");
        // enforce that this contract called uniswap
        require(sender == address(this), "bad origin");
        (UniVars memory uniVars) = abi.decode(data, (UniVars));

        if (uniVars.amountFromReserves > 0) {
            // transfer from reserves and mint to uniswap
            IDollars(dollarAddress).transfer(uniswap_reserve_pair, uniVars.amountFromReserves);
            if (uniVars.amountFromReserves < uniVars.dollarsToUni) {
                // if the amount from reserves > dollarsToUni, we have fully paid for the yCRV tokens
                // thus this number would be 0 so no need to mint
                IDollars(dollarAddress).transfer(uniswap_reserve_pair, uniVars.dollarsToUni.sub(uniVars.amountFromReserves));
            }
        } else {
            // transfer to uniswap
            IDollars(dollarAddress).transfer(uniswap_reserve_pair, uniVars.dollarsToUni);
        }

        uint256 public_goods_perc = IRebaser(rebaser).public_goods_perc();
        address public_goods = IRebaser(rebaser).public_goods();

        // transfer reserve token to reserves
        if (isToken0) {
            if (public_goods != address(0) && public_goods_perc > 0) {
              uint256 amount_to_public_goods = amount1.mul(public_goods_perc).div(10 ** 9);
              SafeERC20.safeTransfer(IERC20(reserveToken), public_goods, amount_to_public_goods);
              emit TreasuryIncreased(amount1.sub(amount_to_public_goods), uniVars.dollarsToUni, uniVars.amountFromReserves, uniVars.mintToReserves);
            } else {
              emit TreasuryIncreased(amount1, uniVars.dollarsToUni, uniVars.amountFromReserves, uniVars.mintToReserves);
            }
        } else {
          if (public_goods != address(0) && public_goods_perc > 0) {
            uint256 amount_to_public_goods = amount0.mul(public_goods_perc).div(10 ** 9);
            SafeERC20.safeTransfer(IERC20(reserveToken), public_goods, amount_to_public_goods);
            emit TreasuryIncreased(amount0.sub(amount_to_public_goods), uniVars.dollarsToUni, uniVars.amountFromReserves, uniVars.mintToReserves);
          } else {
            emit TreasuryIncreased(amount0, uniVars.dollarsToUni, uniVars.amountFromReserves, uniVars.mintToReserves);
          }
        }
    }

    function computeOffPegPerc(uint256 rate, uint256 targetRate)
        private
        view
        returns (uint256)
    {
        if (withinDeviationThreshold(rate, targetRate)) {
            return 0;
        }

        if (rate > targetRate) {
            return rate.sub(targetRate).mul(10 ** 9).div(targetRate);
        } else {
            return targetRate.sub(rate).mul(10 ** 9).div(targetRate);
        }
    }

    function withinDeviationThreshold(uint256 rate, uint256 targetRate)
        private
        view
        returns (bool)
    {
        uint256 deviationThreshold = IRebaser(rebaser).deviationThreshold();
        uint256 absoluteDeviationThreshold = targetRate.mul(deviationThreshold)
            .div(10 ** DECIMALS);

        return (rate >= targetRate && rate.sub(targetRate) < absoluteDeviationThreshold)
            || (rate < targetRate && targetRate.sub(rate) < absoluteDeviationThreshold);
    }

    // add functions to convert assets to stable coins
    // add functions to convert to ETH

    function getDollarCoinExchangeRate()
        public
        returns (uint256)
    {
        address WETH_ADDRESS = IRebaser(rebaser).WETH_ADDRESS();
        address ethPerUsdcOracle = IRebaser(rebaser).ethPerUsdcOracle();
        address ethPerUsdOracle = IRebaser(rebaser).ethPerUsdOracle();

        uint256 ethUsdcPrice = IDecentralizedOracle(ethPerUsdcOracle).consult(WETH_ADDRESS, 1 * 10 ** 18);        // 10^18 decimals ropsten, 10^6 mainnet
        uint256 ethUsdPrice = IDecentralizedOracle(ethPerUsdOracle).consult(WETH_ADDRESS, 1 * 10 ** 18);          // 10^9 decimals
        uint256 dollarCoinExchangeRate = ethUsdcPrice.mul(10 ** 9)                         // 10^18 decimals, 10**9 ropsten, 10**21 on mainnet
            .div(ethUsdPrice);
        
        return dollarCoinExchangeRate;
    }

    function getTargetRate()
        public
        returns (uint256)
    {
        uint256 targetRate = IRebaser(rebaser).getCpi();
        return targetRate;
    }

    // convert USD into reserve asset
    function buyReserveAndTransfer(uint256 mintAmount)
        external
        // onlyRebaser
    {
        uint256 dollarCoinExchangeRate = getDollarCoinExchangeRate();
        uint256 targetRate = getTargetRate();

        uint256 offPegPerc = computeOffPegPerc(dollarCoinExchangeRate, targetRate);
        UniswapPair pair = UniswapPair(uniswap_reserve_pair);
        pair.sync();

        // get reserves
        (uint256 token0Reserves, uint256 token1Reserves, ) = pair.getReserves();

        // check if protocol has excess dollars in the reserve
        uint256 currentBalance = IDollars(dollarAddress).balanceOf(address(this));

        uint256 excess = currentBalance.sub(mintAmount);

        uint256 maxSlippageFactor = IRebaser(rebaser).maxSlippageFactor();
        uint256 tokens_to_max_slippage = uniswapMaxSlippage(token0Reserves, token1Reserves, offPegPerc, maxSlippageFactor);

        UniVars memory uniVars = UniVars({
          dollarsToUni: tokens_to_max_slippage, // how many dollars uniswap needs
          amountFromReserves: excess, // how much of dollarsToUni comes from reserves
          mintToReserves: 0 // how much dollars protocol mints to reserves
        });

        // tries to sell all mint + excess
        // falls back to selling some of mint and all of excess
        // if all else fails, sells portion of excess
        // upon pair.swap, `uniswapV2Call` is called by the uniswap pair contract
        uint256 buyTokens;

        if (isToken0) {
            if (tokens_to_max_slippage > currentBalance) {
                // we already have performed a safemath check on mintAmount+excess
                // so we dont need to continue using it in this code path

                // can handle selling all of reserves and mint
                buyTokens = getAmountOut(currentBalance, token0Reserves, token1Reserves);
                uniVars.dollarsToUni = currentBalance;
                uniVars.amountFromReserves = excess;
                // call swap using entire mint amount and excess; mint 0 to reserves
                pair.swap(0, buyTokens, address(this), abi.encode(uniVars));
            } else {
                if (tokens_to_max_slippage > excess) {
                    // uniswap can handle entire reserves
                    buyTokens = getAmountOut(tokens_to_max_slippage, token0Reserves, token1Reserves);

                    // swap up to slippage limit, taking entire yam reserves, and minting part of total
                    uniVars.mintToReserves = mintAmount.sub((tokens_to_max_slippage.sub(excess)));
                    pair.swap(0, buyTokens, address(this), abi.encode(uniVars));
                } else {
                    // uniswap cant handle all of excess
                    buyTokens = getAmountOut(tokens_to_max_slippage, token0Reserves, token1Reserves);
                    uniVars.amountFromReserves = tokens_to_max_slippage;
                    uniVars.mintToReserves = mintAmount;
                    // swap up to slippage limit, taking excess - remainingExcess from reserves, and minting full amount
                    // to reserves
                    pair.swap(0, buyTokens, address(this), abi.encode(uniVars));
                }
            }
        } else {
            if (tokens_to_max_slippage > currentBalance) {
                // can handle all of reserves and mint
                buyTokens = getAmountOut(currentBalance, token1Reserves, token0Reserves);
                uniVars.dollarsToUni = currentBalance;
                uniVars.amountFromReserves = excess;
                // call swap using entire mint amount and excess; mint 0 to reserves

                emit BuyAmount(buyTokens, tokens_to_max_slippage, token0Reserves, token1Reserves);

                pair.swap(buyTokens, 0, address(this), abi.encode(uniVars));
            } else {
                if (tokens_to_max_slippage > excess) {
                    // uniswap can handle entire reserves
                    buyTokens = getAmountOut(tokens_to_max_slippage, token1Reserves, token0Reserves);

                    // swap up to slippage limit, taking entire yam reserves, and minting part of total
                    uniVars.mintToReserves = mintAmount.sub( (tokens_to_max_slippage.sub(excess)));
                    // swap up to slippage limit, taking entire yam reserves, and minting part of total

                    emit BuyAmount(buyTokens, tokens_to_max_slippage, token0Reserves, token1Reserves);

                    pair.swap(buyTokens, 0, address(this), abi.encode(uniVars));
                } else {
                    // uniswap cant handle all of excess
                    buyTokens = getAmountOut(tokens_to_max_slippage, token1Reserves, token0Reserves);
                    uniVars.amountFromReserves = tokens_to_max_slippage;
                    uniVars.mintToReserves = mintAmount;
                    // swap up to slippage limit, taking excess - remainingExcess from reserves, and minting full amount
                    // to reserves

                    emit BuyAmount(buyTokens, tokens_to_max_slippage, token0Reserves, token1Reserves);

                    pair.swap(buyTokens, 0, address(this), abi.encode(uniVars));
                }
            }
        }
    }

    /**
     * @notice lets msg.sender accept governance
     */
    function _acceptGov()
        external
    {
        require(msg.sender == pendingGov, "!pending");
        address oldGov = gov;
        gov = pendingGov;
        pendingGov = address(0);
        emit NewGov(oldGov, gov);
    }

    /// @notice Moves all tokens to a new reserve contract
    function migrateReserves(
        address newReserve,
        address[] memory tokens
    )
        public
        onlyGov
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            uint256 bal = token.balanceOf(address(this));
            SafeERC20.safeTransfer(token, newReserve, bal);
        }
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    )
        internal
        pure
        returns (uint256 amountOut)
    {
       require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
       require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
       uint256 amountInWithFee = amountIn.mul(997);
       uint256 numerator = amountInWithFee.mul(reserveOut);
       uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
       amountOut = numerator / denominator;
   }

    function sortTokens(
        address tokenA,
        address tokenB
    )
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    function pairFor(
        address factory,
        address token0,
        address token1
    )
        internal
        pure
        returns (address pair)
    {
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f' // init code hash
            ))));
    }

    /// @notice Gets the current amount of reserves token held by this contract
    function reserves()
        public
        view
        returns (uint256)
    {
        return IERC20(reserveToken).balanceOf(address(this));
    }
}
