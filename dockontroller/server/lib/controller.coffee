Docker = require 'dockerode'
ProxyManager = require './proxymanager'
{EventEmitter} = require 'events'
logrotate = require 'logrotate-stream'
request = require 'request'
utils = require '../middlewares/utils'

# if the app just wont start at all, we restart it after RESTART_TIMEOUT
RESTART_TIMEOUT = 3 * 1000
# number of time we start to relaunch an app before considering it broken
MAX_RELAUNCH = 3
# after SPINNING_TIMEOUT, relaunch counter is reset
SPINNING_TIMEOUT = 60 * 1000

module.exports = class DockerCommander

    # docker connection options
    socketPath: process.env.DOCKERSOCK or '/var/run/docker.sock'
    version: 'v1.10'

    constructor: ->
        @docker = new Docker {@socketPath, @version}
        @proxy = new ProxyManager

        @expectedStops = {}
        @relaunches = {}
        @docker.getEvents @handleEventsStream

    # get the ip of the host as visible by containers
    getContainerVisibleIp: ->
        addresses = require('os').networkInterfaces()['docker0']
        return ad.address for ad in addresses when ad.family is 'IPv4'


    # wait for an application to be really started
    # ie. listening on http
    waitListening: (url, timeout, callback) ->
        console.log "WAITING FOR ", url
        i = 0
        do ping = ->
            i += 500
            return callback new Error('timeout') if i > timeout
            console.log(url)
            request.get url, (err, response, body) ->
                console.log(err)
                if err then setTimeout ping, 500
                else callback null

    # useful params
    # Volumes
    # install = pull the image
    install: (imagename, version, params, callback) ->
        console.log "INSTALLING", imagename

        options =
            fromImage: imagename,
            tag: version

        progress = new EventEmitter()

        # pull the image
        # @TODO, ask the registry for how many steps to expect
        @docker.createImage options, (err, res) ->

            lastId = null
            step = 0

            res.on 'end', -> callback null
            res.on 'error', (err) -> callback err
            res.on 'data', (data) ->
                try data = JSON.parse data.toString()
                catch e then return #meh

                if data.id isnt lastId
                    lastId = data.id
                    step++

                # make a not so crazy percentage
                switch data.status
                    when 'Pulling metadata' then p = 0.1
                    when 'Pulling fs layer' then p = 0.2
                    when 'Download complete' then p = 0.9
                    when 'Downloading'
                        p = 0.2 + 0.7 * (data.progressDetail.current / data.progressDetail.total)
                    else return #meh

                progress.emit 'progress', {step, id: lastId, progress: p}


        return progress

    # Update =
    #     * Install new image
    #     * Uninstall old image
    #     * Start new image
    updateApplication: (imagename, env, callback) ->
        @uninstallApplication imagename.split('/')[1], (err) =>
            @install imagename, "latest", {}, (err) =>
                    options = 
                        PublishAllPorts: true
                        Links: ['datasystem:datasystem']
                        Env: env
                @start imagename, options, callback

    # uninstall = rmi the image
    uninstallApplication: (slug, callback) ->
        container = @docker.getContainer slug

        @stop slug, (err, image) =>
            return callback err if err

            image = @docker.getImage image
            image.remove callback

    # fire up an ambassador that allow container to speak to the host
    ambassador: (slug, port, callback) ->
        console.log "AMBASSADOR", slug, port

        ip = @getContainerVisibleIp()
        options =
            name: slug
            Image: 'cozy/ambassador'
            Env: "#{slug.toUpperCase()}_PORT_#{port}_TCP=tcp://#{ip}:#{port}"
            ExposedPorts: {}

        options.ExposedPorts["#{port}/tcp"] = {}

        @docker.createContainer options, (err) =>
            return callback err if err
            container = @docker.getContainer slug
            container.start {}, callback

    # useful params
    # Links
    # start = create & start a container based on the image
    start: (imagename, params, callback) ->

        slug = imagename.split('/')[1]

        options =
            'name': slug
            'Image': imagename
            'Tty': false

        options[key] = value for key, value of params

        # create a container
        @docker.createContainer options, (err) =>

            console.log "STARTING", slug
            container = @docker.getContainer slug

            # prepare a WritableStream for logging
            # @TODO, do the piping in child process ?
            logfile = "/var/log/cozy_#{slug}.log"
            logStream = logrotate file: logfile, size: '100k', keep: 3

            singlepipe = stream: true, stdout: true, stderr: true
            container.attach singlepipe, (err, stream) =>
                return callback err if err

                stream.setEncoding 'utf8'
                stream.pipe logStream, end: true

                container.start options, (err) =>
                    return callback err if err

                    container.inspect (err, data) =>
                        return callback err if err

                        # we wait for the container to actually start (ie. listen)
                        pingHost = data.NetworkSettings.IPAddress
                        for key, val of data.NetworkSettings.Ports
                            pingPort = key.split('/')[0]
                            hostPort = val?[0].HostPort
                            break

                        pingUrl = "http://#{pingHost}:#{pingPort}/"
                        @waitListening pingUrl, 20000, (err) =>
                            callback err, data, hostPort

    # stop = stop & remove the container
    stop: (slug, callback) ->
        container = @docker.getContainer slug

        container.inspect (err, data) =>
            return callback err if err
            image = data.Image

            doRemove = ->
                container.remove (err) ->
                    return callback err if err

                    callback null, image

            if not data.State.Running
                return doRemove()


            @expectedStops[data.Id] = true
            container.stop t: 1, (err) ->
                return callback err if err
                doRemove()

    # app
    exist: (slug, callback) ->
        container = @docker.getContainer slug
        container.inspect (err, data) ->
            return callback null, !err

    # list running apps
    running: (callback) ->
        @docker.listContainers (err, containers) ->
            return callback err if err
            result = containers.map (container) ->
                name: container.Names[0].split('/')[-1..][0]
                port: container.Ports[0].PublicPort

            callback null, result


    handleEventsStream: (err, stream) =>

        if err
            console.log "FAILLED TO CONNECT EVENTS", err
            return

        # @TODO : what to do on error ?
        stream.on 'end', =>
            # docker has terminated the stream
            # attempt to reconnect
            @docker.getEvents @handleEventsStream

        stream.on 'data', @handleEvent

    handleEvent: (data) =>
        try event = JSON.parse data.toString()
        catch e then return #meh?

        # event shall be an object with fields
        # status in create, start, stop, destroy
        # id: container id
        # from: container's image ("cozy/foo:version")
        # time: timestamp of this event

        if event.status is 'stop'

            if @expectedStops[event.id]
                @expectedStops[event.id] = false
                return # all is well

            # this is an unexpected stop (ie. the app broke)
            console.log "Unexpected stop of ", event.from
            @relaunches[event.id] ?= count: 0, timeout: null #defaults

            {count, timeout} = @relaunches[event.id]
            clearTimeout timeout if timeout

            if count > MAX_RELAUNCH
                console.log "App ", event.from, "failled too many times"
                # @ TODO mark this app as broken
                # @ TODO other cozy wide stategies
                # (restart stack, revert last DS op)
            else
                # we restart the container
                @docker.getContainer(event.id).start (err) =>

                    if err
                        # failled to start, let's try again later
                        console.log "Failled to start app", event.from
                        tryAgain = => @handleEvent event
                        return setTimeout tryAgain, RESTART_TIMEOUT

                    else
                        console.log "App restarted", event.from
                        @relaunches[event.id].timeout = setTimeout =>
                            console.log "Resetting counter for ", event.from
                            @relaunches[event.id] = count: 0, timeout: null
                        , SPINNING_TIMEOUT


    # preconfigured start for stack
    startCouch: (callback) ->
        @start 'cozy/couchdb', {}, callback

    startDataSystem: (callback) ->
        @start 'cozy/datasystem',
            Links: ['couchdb:couch']
            Env: 'NAME=data-system TOKEN=' + utils.getToken()
        , (err, data) =>
            return callback err if err
            @dataSystemHost = data.NetworkSettings.IPAddress
            @dataSystemPort = key.split('/')[0] for key, val of data.NetworkSettings.Ports
            console.log "DS STARTED", @dataSystemHost, @dataSystemPort
            callback null, data

    startHome: (callback) ->
        @start 'cozy/home',
            PublishAllPorts: true
            Links: ['datasystem:datasystem', 'proxy:proxy', 'controller:controller']
            Env: 'NAME=home TOKEN=' + utils.getToken()
        , callback

    startProxy: (homePort, callback) ->
        ip = @getContainerVisibleIp()
        env =
            HOST: '0.0.0.0'
            DATASYSTEM_HOST: @dataSystemHost
            DATASYSTEM_PORT: @dataSystemPort
            DEFAULT_REDIRECT_PORT: homePort
            NAME: 'proxy'
            TOKEN: utils.getToken()

        @proxy.start env, (err) =>
            return callback err if err
            @waitListening 'http://localhost:9104/', 30000, callback

    # start a normal application
    # only link to the datasystem
    startApplication: (slug, env, callback) ->
        @start slug,
            PublishAllPorts: true
            Links: ['datasystem:datasystem']
            Env: env
        , callback
