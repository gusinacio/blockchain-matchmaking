// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "./RatingSystem.sol";

contract EloRating is RatingSystem {
    uint256 public constant VICTORY = INVERSE_BASIS_POINT;
    uint256 public constant DRAW = VICTORY / 2;
    // K Factor for Elo Rating
    uint256 public kFactor;

    event KFactorUpdate(uint256 newKFactor);
    event EloUpdate(address indexed player, uint256 elo);
    mapping(address => PlayerRating) playerElo;

    constructor(address addr) RatingSystem(addr) {}

    struct PlayerRating {
        uint256 elo;
        uint256 nonce;
        uint256 lastUpdatedRating;
        int256 nextEloUpdate;
    }

    /**
        Update k factor for Elo Rating
    */
    function updateKFactor(uint256 newKFactor) public onlyOwner {
        kFactor = newKFactor;
        emit KFactorUpdate(newKFactor);
    }

    function writeMatchResult(
        GameLibrary.Match memory m,
        GameLibrary.MatchResult result
    ) public override onlyGameContract {
        bytes32 hash = hashToSignMatch(m);
        require(
            matches[hash].state == MatchState.RUNNING,
            "match isn't running"
        );
        // We save before the update to evict wrong calculation
        uint256 ratingA = getPlayerRating(m.playerA.addr);
        uint256 ratingB = getPlayerRating(m.playerB.addr);

        // Check for players score
        uint256 scoreplayerA = 0;
        uint256 scoreplayerB = 0;
        address winner;
        if (result == GameLibrary.MatchResult.PLAYER_A_WIN) {
            scoreplayerA = VICTORY;
            winner = m.playerA.addr;
        } else if (result == GameLibrary.MatchResult.PLAYER_B_WIN) {
            scoreplayerB = VICTORY;
            winner = m.playerB.addr;
        } else {
            scoreplayerA = DRAW;
            scoreplayerB = DRAW;
        }

        uint256 qA = 10**(ratingA / 400);
        uint256 qB = 10**(ratingB / 400);

        // Set the match to finished
        matches[hash].state = MatchState.FINISHED;
        matches[hash].winner = winner;

        // Calculate the expected score for player 1
        uint256 expectedScore = (qA / (qA + qB)) * INVERSE_BASIS_POINT;
        calculateElo(m.playerA.addr, expectedScore, scoreplayerA);

        // Calculate the expected score for player 2
        expectedScore = (qB / (qA + qB)) * INVERSE_BASIS_POINT;
        calculateElo(m.playerB.addr, expectedScore, scoreplayerB);
    }

    /**
        Calculate elo using initial formula
        WIP: It needs some testing how uint handles the decimal part of the formula
    */
    function calculateElo(
        address player,
        uint256 expectedScore,
        uint256 scoredPoints
    ) internal {
        int256 eloChange = ((int256(kFactor) *
            (int256(scoredPoints) - int256(expectedScore))) /
            int256(INVERSE_BASIS_POINT));
        updatePlayerRating(player, eloChange);
    }

    function createMatch(
        GameLibrary.Match memory m,
        GameLibrary.Sig memory pAsig,
        GameLibrary.Sig memory pBsig
    ) public override returns (bytes32 hash) {
        hash = requireValidMatch(m, pAsig, pBsig);

        matches[hash].state = MatchState.RUNNING;
        // Update nonces WIP
        require(
            m.playerA.nonce == playerElo[m.playerA.addr].nonce++,
            "pB nonce doesn't match"
        );
        require(
            m.playerB.nonce == playerElo[m.playerB.addr].nonce++,
            "pB nonce doesn't match"
        );

        // Emit events
        emit MatchCreate(m.playerA.addr, m.playerB.addr, m.timestamp);
    }

    function updatePlayerRating(address p, int256 newEloRating) internal {
        PlayerRating storage rating = playerElo[p];
        int256 eloUpdate = newEloRating;
        if (evaluationPeriod > 0) {
            if (rating.lastUpdatedRating + evaluationPeriod > block.timestamp) {
                rating.nextEloUpdate += eloUpdate;
                return;
            } else {
                eloUpdate += rating.nextEloUpdate;
                rating.nextEloUpdate = 0;
            }
        }

        rating.elo = uint256(int256(rating.elo) + eloUpdate);
        rating.lastUpdatedRating = block.timestamp;
        emit EloUpdate(p, rating.elo);
    }

    function getPlayerRating(address p) private view returns (uint256 elo) {
        elo = playerElo[p].elo;
        if (elo == 0) elo = 1500;
    }
}
