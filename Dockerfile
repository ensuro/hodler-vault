FROM ethereum/solc:0.8.6 as build-deps

FROM node:14
COPY --from=build-deps /usr/bin/solc /usr/bin/solc
RUN echo 'alias hh="npx hardhat"' >> /root/.bashrc

WORKDIR /code
