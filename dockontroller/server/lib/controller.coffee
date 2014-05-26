Docker = require 'dockerode'
ProxyManager = require './proxymanager'
{EventEmitter} = require 'events'
logrotate = require 'logrotate-stream'
request = require 'request'
utils = require '../middlewares/utils'

module.exports = class DockerCommander

    # docker connection options
    socketPath: process.env.DOCKERSOCK or '/var/run/docker.sock'
    version: 'v1.10'

    constructor: ->
        @docker = new Docker {@socketPath, @version}
        @proxy = new ProxyManager

    # get the ip of the host as visible by containers
    getContainerVisibleIp: ->
        addresses = require('os').networkInterfaces()['docker0']
        return ad.address for ad in addresses when ad.family is 'IPv4'


    # wait for an application to be really started
    # ie. listening on http
    waitListening: (url, timeout, callback) ->
        i = 0
        do ping = ->
            i += 500
            console.log "PING", url, i, '/', timeout
            return callback new Error('timeout') if i > timeout
            request.get url, (err, response, body) ->
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

    # uninstall = rmi the image
    uninstallApplication: (slug, callback) ->
        container = @docker.getContainer slug

        @stop slug, (err, image) ->
            return callback err if err

            image = @docker.getImage image
            image.remove callback

    # fire up an ambassador that allow container to speak to the host
    ambassador: (slug, port, callback) ->
        console.log "AMBASSADOR", slug, port

        ip = @getContainerVisibleIp()
        options =
            name: slug
            Image: 'aenario/ambassador'
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

        container.inspect (err, data) ->
            return callback err if err
            image = data.Image

            doRemove = ->
                container.remove (err) ->
                    return callback err if err

                    callback null, image

            if not data.State.Running
                return doRemove()

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
                name: container.Names[0].split('/')[..-1]
                port: container.Ports[0].PublicPort

            callback null, result

    # preconfigured start for stack
    startCouch: (callback) ->
        @start 'mycozycloud/couchdb', {}, callback

    startDataSystem: (callback) ->
        @start 'mycozycloud/datasystem',
            Links: ['couchdb:couch']
            Env: 'NAME=data-system TOKEN=' + utils.getToken()
        , (err, data) =>
            return callback err if err
            @dataSystemHost = data.NetworkSettings.IPAddress
            @dataSystemPort = key.split('/')[0] for key, val of data.NetworkSettings.Ports
            console.log "DS STARTED", @dataSystemHost, @dataSystemPort
            callback null, data

    startHome: (callback) ->
        @start 'mycozycloud/home',
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
