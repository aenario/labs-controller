// Generated by CoffeeScript 1.7.1
var americano, config;

americano = require('americano');

config = {
  common: {
    use: [
      americano.bodyParser(), americano.methodOverride(), americano.errorHandler({
        dumpExceptions: true,
        showStack: true
      })
    ]
  },
  development: [americano.logger('dev')],
  production: [americano.logger('short')],
  plugins: []
};

module.exports = config;
