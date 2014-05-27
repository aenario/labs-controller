helpers = require './helpers'
should = require 'should'

commander = helpers.commander

describe 'lib/controller.coffee - Controller', ->

    before helpers.stopAllContainers
    before helpers.deleteAllContainers

    # before helpers.deleteAllImages # should be uncommented for full test, but way too long

    it 'installs the cozy/datasystem image', (done) ->
        @timeout 5 * 60 * 1000
        progressHandler = commander.install 'cozy/datasystem', 'latest', {}, done

        progressHandler.on 'progress', (event) =>
            @progressHandlerCalled = true
            event.progress.should.be.within 0, 1

    it 'and gives a eventEmitter to follow', ->
        @progressHandlerCalled.should.be.true

    it 'installs the cozy/home image', (done) ->
        @timeout 5 * 60 * 1000
        commander.install 'cozy/home', 'latest', {}, done

    it 'installs the cozy/ambassador image', (done) ->
        @timeout 5 * 60 * 1000
        commander.install 'cozy/ambassador', 'latest', {}, done

    it 'installs the cozy/couchdb image', (done) ->
        @timeout 5 * 60 * 1000
        commander.install 'cozy/couchdb', 'latest', {}, done

    it 'starts couch', (done) ->
        @timeout 5000
        commander.startCouch done

    it 'starts the DS', (done) ->
        @timeout 5000
        commander.startDataSystem done

    it 'creates proxy ambassador', (done) ->
        @timeout 5000
        commander.ambassador 'proxy', 9104, done

    it 'creates controller ambassador', (done) ->
        @timeout 5000
        commander.ambassador 'controller', 9002, done

    it 'starts home', (done) ->
        @timeout 5000
        fakeServer = require('http').createServer (req, res) ->
            res.writeHead 200, "Content-type": 'application/json'
            res.end '[]', 'utf8'

        fakeServer.listen 9002, (err) ->
            return done err if err

            commander.startHome (err, data, homePort) =>
                @homePort = homePort
                done err

    it 'starts the proxy', (done) ->
        @timeout 20000
        commander.startProxy @homePort, done


    it 'all containers are up and linked', (done) ->
        commander.running (err, applications) ->
            return done err if err
            applications = applications.map (a) -> a.name
            ('couchdb' in applications).should.ok
            ('datasystem' in applications).should.ok
            ('proxy' in applications).should.ok
            ('controller' in applications).should.ok
            ('home' in applications).should.ok
            done null

    it 'installs an application', (done) ->
        @timeout 20000
        commander.install 'aenario/labs-controller-nodejsapp', 'latest', {}, done

    it 'starts an application', (done) ->
        @timeout 5000
        commander.startApplication 'aenario/labs-controller-nodejsapp', {}, done

    it 'stop an application', (done) ->
        @timeout 5000
        commander.startApplication 'aenario/labs-controller-nodejsapp', {}, done

    it 'updates an application', (done) ->
        @timeout 5000
        commander.updateApplication 'aenario/labs-controller-nodejsapp', 'v2', done

    it 'starts the updated application', (done) ->


    it 'downdates while the app is running (not useful, but it cans)', (done) ->




    it 'uninstalls an application', (done) ->