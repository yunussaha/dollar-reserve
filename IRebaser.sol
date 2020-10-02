pragma solidity >=0.5.15;


interface IRebaser {
    function public_goods_perc() external view returns (uint256);
    function WETH_ADDRESS() external view returns (address);
    function getCpi() external view returns (uint256);
    function public_goods() external view returns (address);
    function deviationThreshold() external view returns (uint256);
    function ethPerUsdcOracle() external view returns (address);
    function ethPerUsdOracle() external view returns (address);
    function maxSlippageFactor() external view returns (uint256);
    function uniswapV2Pool() external view returns (address);
}