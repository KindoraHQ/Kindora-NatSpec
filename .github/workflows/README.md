```text
This CI workflow runs on pushes and pull requests to main:

- Installs dependencies with npm ci
- Runs solhint on contracts/
- Runs Hardhat unit tests (npx hardhat test)
- Runs solidity-coverage (npx hardhat coverage)
- Runs Slither static analysis via trailofbits/slither-action and uploads a JSON report

Artifacts:
- coverage-report (uploaded directory produced by solidity-coverage)
- slither-report (JSON produced by Slither)

If you want further enhancements, consider:
- Uploading coverage data to codecov or coveralls
- Running Slither in a separate job with a pinned image to speed up analysis
- Adding a security scan (MythX/ConsenSys Diligence or other)
```
