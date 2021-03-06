// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "./IndexBase.sol";

contract FinanceIndexV2 is IndexBase, OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC1155Upgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint;
    using StringsUpgradeable for uint;

    IUniswapV2Router02 public router;
    IUniswapV2Factory public factory;
    address public matter;
    address public platform;
    uint public fee;

    mapping(address => uint) public creatorTotalFee;
    mapping(address => uint) public creatorClaimedFee;

    function initialize(string memory _uri, address _matter, address _platform, uint _fee) public initializer {
        super.__Ownable_init();
        super.__ReentrancyGuard_init();
        super.__ERC1155_init(_uri);

        if (block.chainid == 1) {
            // ethereum
            router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
            factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
        } else if (block.chainid == 56) {
            // bsc
            router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
            factory = IUniswapV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
        } else if (block.chainid == 250) {
            // fantom
            router = IUniswapV2Router02(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
            factory = IUniswapV2Factory(0x152eE697f2E276fA89E96742e9bB9aB1F2E61bE3);
        } else if (block.chainid == 43114) {
            // avalanche
            router = IUniswapV2Router02(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
            factory = IUniswapV2Factory(0xefa94DE7a4656D787667C749f7E1223D71E9FD88);
        }

        if (_matter != address(0)) {
            require(factory.getPair(_matter, getWETH()) != address(0), "pair not exists");
        }
        matter = _matter;

        if (_platform == address(0)) {
            platform = address(this);
        } else {
            platform = _platform;
        }

        fee = _fee;
    }

    function createIndex(CreateReq memory req) external {
        require(req.underlyingTokens.length > 0, "invalid length");
        require(req.underlyingTokens.length == req.underlyingAmounts.length, "invalid length");

        address weth = getWETH();
        for (uint i = 0; i < req.underlyingTokens.length; i++) {
            require(factory.getPair(req.underlyingTokens[i], weth) != address(0), "pair not exists");
        }

        uint nftId = nextNftId++;

        Index memory index;
        index.name = req.name;
        index.metadata = req.metadata;
        index.creator = msg.sender;
        index.underlyingTokens = req.underlyingTokens;
        index.underlyingAmounts = req.underlyingAmounts;
        indices[nftId] = index;

        emit IndexCreated(msg.sender, nftId, req.name);
    }

    function mint(uint nftId, uint nftAmount, uint[] memory amountInMaxs) external payable nonReentrant {
        Index memory index = indices[nftId];
        require(index.creator != address(0), "index not exists");
        require(msg.value > fee, "invalid value");
        require(index.underlyingTokens.length == amountInMaxs.length, "invalid length of amountInMaxs");

        uint totalInAmount = msg.value.sub(fee);
        uint remaining = totalInAmount;
        address[] memory path = new address[](2);
        path[0] = getWETH();
        uint deadline = block.timestamp.add(20 minutes);
        for (uint i = 0; i < index.underlyingTokens.length; i++) {
            uint amountOut = index.underlyingAmounts[i].mul(nftAmount);
            path[1] = index.underlyingTokens[i];
            uint[] memory amounts = router
                .swapETHForExactTokens{value: amountInMaxs[i]}(amountOut, path, address(this), deadline);
            remaining = remaining.sub(amounts[0]);
        }

        super._mint(msg.sender, nftId, nftAmount, "");
        _handleFee(nftId);
        payable(msg.sender).transfer(remaining);

        emit Mint(msg.sender, nftId, nftAmount, totalInAmount.sub(remaining));
    }

    function burn(uint nftId, uint nftAmount, uint[] memory amountOutMins) external nonReentrant {
        Index memory index = indices[nftId];
        require(index.creator != address(0), "index not exists");
        require(index.underlyingTokens.length == amountOutMins.length, "invalid length of amountOutMins");

        uint totalOutAmount = 0;
        address[] memory path = new address[](2);
        path[1] = getWETH();
        uint deadline = block.timestamp.add(20 minutes);
        for (uint i = 0; i < index.underlyingTokens.length; i++) {
            uint amountIn = index.underlyingAmounts[i].mul(nftAmount);
            path[0] = index.underlyingTokens[i];
            IERC20Upgradeable(index.underlyingTokens[i]).approve(address(router), amountIn);
            uint[] memory amounts = router
                .swapExactTokensForETH(amountIn, amountOutMins[i], path, address(this), deadline);
            totalOutAmount = totalOutAmount.add(amounts[amounts.length-1]);
        }

        super._burn(msg.sender, nftId, nftAmount);
        if (totalOutAmount > 0) {
            payable(msg.sender).transfer(totalOutAmount);
        }

        emit Burn(msg.sender, nftId, nftAmount, totalOutAmount);
    }

    function creatorClaim() external nonReentrant {
        uint creatorFee = creatorTotalFee[msg.sender].sub(creatorClaimedFee[msg.sender]);
        if (creatorFee > 0) {
            if (matter != address(0)) {
                uint amountOutMin = 0;
                address[] memory path = new address[](2);
                path[0] = getWETH();
                path[1] = matter;
                uint deadline = block.timestamp.add(20 minutes);
                router.swapExactETHForTokens{value: creatorFee}(amountOutMin, path, msg.sender, deadline);
            } else {
                payable(msg.sender).transfer(creatorFee);
            }
            creatorClaimedFee[msg.sender] = creatorTotalFee[msg.sender];
        }
    }

    function approveERC20(address token, address spender, uint amount) external onlyOwner {
        IERC20Upgradeable(token).approve(spender, amount);
    }

    function setFee(uint fee_) external onlyOwner {
        fee = fee_;
    }

    function setPlatform(address platform_) external onlyOwner {
        platform = platform_;
    }

    function setUniswapV2Router(address router_) external onlyOwner {
        router = IUniswapV2Router02(router_);
    }

    function setUniswapV2Factory(address factory_) external onlyOwner {
        factory = IUniswapV2Factory(factory_);
    }

    function setURI(string memory _uri) external onlyOwner {
        _setURI(_uri);
    }

    function uri(uint256 id) public view override returns (string memory) {
        string memory baseURI = super.uri(id);
        return bytes(baseURI).length > 0
            ? string(abi.encodePacked(baseURI, "?nftId=", id.toString(), "&chainId=", block.chainid.toString()))
            : '';
    }

    function getWETH() public view returns (address) {
        // avalanche
        if (block.chainid == 43114) {
            return 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        }

        return router.WETH();
    }


    function _handleFee(uint nftId) private {
        uint halfFee = fee.div(2);
        if (halfFee > 0) {
            if (platform != address(this)) {
                payable(platform).transfer(halfFee);
            }
            creatorTotalFee[indices[nftId].creator] = creatorTotalFee[indices[nftId].creator].add(halfFee);
            emit FeeReceived(nftId, platform, indices[nftId].creator, halfFee, halfFee);
        }
    }

    event Received(address, uint);
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}
