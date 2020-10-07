pragma solidity ^0.6.2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IBrainLootbox.sol";

library SafeMathInt {
  function mul(int256 a, int256 b) internal pure returns (int256) {
  // Prevent overflow when multiplying INT256_MIN with -1
  // https://github.com/RequestNetwork/requestNetwork/issues/43
  require(!(a == - 2**255 && b == -1) && !(b == - 2**255 && a == -1));

  int256 c = a * b;
  require((b == 0) || (c / b == a));
  return c;
}

  function div(int256 a, int256 b) internal pure returns (int256) {
    // Prevent overflow when dividing INT256_MIN by -1
    // https://github.com/RequestNetwork/requestNetwork/issues/43
    require(!(a == - 2**255 && b == -1) && (b > 0));

    return a / b;
  }

  function sub(int256 a, int256 b) internal pure returns (int256) {
    require((b >= 0 && a - b <= a) || (b < 0 && a - b > a));

    return a - b;
  }

  function add(int256 a, int256 b) internal pure returns (int256) {
    int256 c = a + b;
    require((b >= 0 && c >= a) || (b < 0 && c < a));
    return c;
  }

  function toUint256Safe(int256 a) internal pure returns (uint256) {
    require(a >= 0);
    return uint256(a);
  }
}

library SafeMathUint {
  function toInt256Safe(uint256 a) internal pure returns (int256) {
    int256 b = int256(a);
    require(b >= 0);
    return b;
  }
}

interface IFeeDistributor {
  function processTransfer() external;
  function pendingFarmAmount() external view returns (uint256);
}

contract LockedLPFarm is Ownable {
    using SafeMath for uint256;
    using SafeMathUint for uint256;
    using SafeMathInt for int256;
    
    address public LPAddress;
    address public DistributorAddress;
    address public BrainAddress;
    address public LootboxAddress;

    constructor(address _brain, address _lp, address _distributor) public {
      LPAddress = _lp;
      DistributorAddress = _distributor;
      BrainAddress = _brain;
    }

    function setLootboxAddress(address _address) public onlyOwner {
      LootboxAddress = _address;
    }

    function setDistributorAddress(address _address) public onlyOwner {
      DistributorAddress = _address;
    }

	mapping(address => uint256) private lpBalance;
	mapping(address => uint256) public lastUpdateTime;
	mapping(address => uint256) public points;

	event Staked(address indexed user, uint256 amount);
	event Withdrawn(address indexed user, uint256 amount);

	modifier updateReward(address account) {
		if (account != address(0)) {
			points[account] = earned(account);
			lastUpdateTime[account] = block.timestamp;
		}
		_;
	}

    function balanceOf(address account) public view returns (uint256) {
        return lpBalance[account];
    }


    function earned(address account) public view returns (uint256) {
		uint256 blockTime = block.timestamp;
		return
			points[account].add(
				blockTime.sub(lastUpdateTime[account]).mul(1e18).div(86400).mul(
					(balanceOf(account).mul(25000)).div(1e18)
				)
			);
	}

	function stake(uint256 amount) public updateReward(msg.sender) {
 		require(amount.add(balanceOf(msg.sender)) <= 200000000000000, "Cannot stake more than 0.0002 Locked LP");
 	    IERC20(LPAddress).transferFrom(msg.sender, address(this), amount);
 	    totalSupply = totalSupply.add(amount);
 	    distributeDividends();
 	    magnifiedDividendCorrections[msg.sender] = magnifiedDividendCorrections[msg.sender].sub((magnifiedDividendPerShare.mul(amount)).toInt256Safe());
        lpBalance[msg.sender] = lpBalance[msg.sender].add(amount);
		emit Staked(msg.sender, amount);
	}

	function withdraw(uint256 amount) public updateReward(msg.sender) {
		require(amount > 0, "Cannot withdraw 0");
		require(amount <= balanceOf(msg.sender), "Cannot withdraw more than balance");
		IERC20(LPAddress).transfer(msg.sender, amount);
		totalSupply = totalSupply.sub(amount);
		distributeDividends();
		magnifiedDividendCorrections[msg.sender] = magnifiedDividendCorrections[msg.sender].add((magnifiedDividendPerShare.mul(amount)).toInt256Safe());
        lpBalance[msg.sender] = lpBalance[msg.sender].sub(amount);
		emit Withdrawn(msg.sender, amount);
	}

	function exit() external {
		withdraw(balanceOf(msg.sender));
	}
    
	function redeem(uint256 _lootbox) public updateReward(msg.sender) {
	    distributeDividends();
	    uint256 price = IBrainLootbox(LootboxAddress).getPrice(_lootbox);
		require(price > 0, "Loot not found");
		require(points[msg.sender] >= price, "Not enough points to redeem");
		IBrainLootbox(LootboxAddress).redeem(_lootbox);
		points[msg.sender] = points[msg.sender].sub(price);
	}
	
	// $BRAIN Dividends
	// Based off https://github.com/Roger-Wu/erc1726-dividend-paying-token
	event DividendsDistributed(uint256 amount);
	event DividendWithdrawn(address to, uint256 amount);
	
	uint256 private totalSupply;
	address public Distributor;
	
	function setDistributor(address _Distributor) public onlyOwner {
	   Distributor = _Distributor;
	}
	
	uint256 constant internal magnitude = 2**128;
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;
    
    uint256 internal lastBrainBalance;
    
    function distributeDividends() public {
        uint256 currentBrainBalance = IERC20(BrainAddress).balanceOf(address(this));
        if (totalSupply > 0 && currentBrainBalance > lastBrainBalance) {
            uint256 amount = currentBrainBalance.sub(lastBrainBalance);
            lastBrainBalance = amount;
            magnifiedDividendPerShare = magnifiedDividendPerShare.add(amount.mul(magnitude) / totalSupply);
            emit DividendsDistributed(amount);
        }
    }
    
    function accumulativeDividendOf(address _owner) public view returns(uint256) {
        return magnifiedDividendPerShare.mul(balanceOf(_owner)).toInt256Safe().add(magnifiedDividendCorrections[_owner]).toUint256Safe() / magnitude;
    }
    
    function withdrawableDividendOf(address _owner) public view returns(uint256) {
        return accumulativeDividendOf(_owner).sub(withdrawnDividends[_owner]);
    }

    function pendingDividendsOf(address _owner) public view returns (uint256) {
	uint256 pending = IFeeDistributor(DistributorAddress).pendingFarmAmount();
	uint256 magnified = magnifiedDividendPerShare.add(pending.mul(magnitude) / totalSupply);
	uint256 accumulativeDiv = magnified.mul(balanceOf(_owner)).toInt256Safe().add(magnifiedDividendCorrections[_owner]).toUint256Safe() / magnitude;
	return accumulativeDiv.sub(withdrawnDividends[_owner]);
    }
    
    function withdrawDividend() public {
        distributeDividends();
        uint256 _withdrawableDividend = withdrawableDividendOf(msg.sender);
        if (_withdrawableDividend > 0) {
            withdrawnDividends[msg.sender] = withdrawnDividends[msg.sender].add(_withdrawableDividend);
            emit DividendWithdrawn(msg.sender, _withdrawableDividend);
            IERC20(BrainAddress).transfer(msg.sender, _withdrawableDividend);
            lastBrainBalance = lastBrainBalance.sub(_withdrawableDividend);
        }
    }
}