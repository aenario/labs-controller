# This program is suited only to manage your cozy installation from the inside
# Moreover app management works only for apps make by Cozy Cloud company.
# If you want a friendly application manager you should use the
# appmanager.coffee script.

require "colors"

program = require 'commander'
async = require "async"
fs = require "fs"
exec = require('child_process').exec
spawn = require('child_process').spawn

Client = require("request-json").JsonClient
ControllerClient = require("cozy-clients").ControllerClient
axon = require 'axon'

pkg = require '../package.json'
version = pkg.version

couchUrl = "http://localhost:5984/"
dataSystemUrl = "http://localhost:9101/"
indexerUrl = "http://localhost:9102/"
controllerUrl = "http://localhost:9002/"
homeUrl = "http://localhost:9103/"
proxyUrl = "http://localhost:9104/"

homeClient = new Client homeUrl
statusClient = new Client ''
appsPath = '/usr/local/cozy/apps'



## Helpers

getHomePort = (cb) ->
    exec 'docker ps | grep cozy/home', (err, body, res) ->
        port = (body.split('0.0.0.0:')[1]).split('->')[0]
        cb port

getToken = () ->
    if fs.existsSync '/etc/cozy/controller.token'
        try
            token = fs.readFileSync '/etc/cozy/controller.token', 'utf8'
            token = token.split('\n')[0]
            return token
        catch err
            console.log("Are you sure, you are root ?")
            return null
    else
        return null


getAuthCouchdb = (callback) ->
    fs.readFile '/etc/cozy/couchdb.login', 'utf8', (err, data) =>
        if err
            console.log "Cannot read login in /etc/cozy/couchdb.login"
            callback err
        else
            username = data.split('\n')[0]
            password = data.split('\n')[1]
            callback null, username, password

waitInstallComplete = (slug, callback) ->    
    axon   = require 'axon'
    socket = axon.socket 'sub-emitter'
    socket.connect 9105

    timeoutId = setTimeout ->
        socket.close()

        getHomePort (homeport) ->
            homeClient = new Client "http://localhost:#{homeport}/"
            homeClient.get "api/applications/", (err, res, apps) ->
                return unless apps?.rows?

                for app in apps.rows
                    console.log slug, app.slug, app.state, app.port
                    if app.slug is slug and app.state is 'installed' and app.port
                        statusClient.host = "http://localhost:#{app.port}/"
                        statusClient.get "", (err, res) ->
                            if res?.statusCode in [200, 403]
                                callback null, state: 'installed'
                            else
                                handleError null, null, "Install home failed"
                        return

                handleError null, null, "Install home failed"

    , 12000

    socket.on 'application.update', (id) ->
        clearTimeout timeoutId
        socket.close()

        dSclient = new Client dataSystemUrl
        dSclient.setBasicAuth 'home', token if token = getToken()
        dSclient.get "data/#{id}/", (err, response, body) ->
            if response.statusCode is 401
                dSclient.setBasicAuth 'home', ''
                dSclient.get "data/#{id}/", (err, response, body) ->
                    callback err, body
            else
                callback err, body

handleError = (err, body, msg) ->
    console.log err if err
    console.log msg
    if body?
        if body.msg?
           console.log body.msg
        else if body.error?.message?
            console.log "An error occured."
            console.log body.error.message
            console.log body.error.result
            console.log body.error.code
            console.log body.error.blame
        else console.log body
    process.exit 1


token = getToken()
client = new ControllerClient
    token: token

manifest =
   "domain": "localhost"
   "repository":
       "type": "git",
   "scripts":
       "start": "server.coffee"


program
  .version(version)
  .usage('<action> <app>')


## Applications management ##

# Install
program
    .command("install <app> ")
    .description("Install application")
    .option('-r, --repo <repo>', 'Use specific repo')
    .option('-d, --displayName <displayName>', 'Display specific name')
    .action (app, options) ->
        getHomePort (homeport) ->
            manifest.name = app
            if options.displayName?
                manifest.displayName = options.displayName
            else
                manifest.displayName = app
            manifest.user = app
            console.log "Install started for #{app}..."
            if app in ['datasystem', 'home', 'proxy', 'couchdb']
                unless options.repo?
                    manifest.repository.url =
                        "https://github.com/mycozycloud/cozy-#{app}.git"
                else
                    manifest.repository.url = options.repo
                client.clean manifest, (err, res, body) ->
                    client.start manifest, (err, res, body)  ->
                        if err or body.error?
                            handleError err, body, "Install failed"
                        else
                            client.brunch manifest, =>
                                console.log "#{app} successfully installed"
            else
                unless options.repo?
                    manifest.git =
                        "https://github.com/mycozycloud/cozy-#{app}.git"
                else
                    manifest.git = options.repo
                path = "api/applications/install"
                homeClient = new Client "http://localhost:#{homeport}/"
                homeClient.post path, manifest, (err, res, body) ->
                    if err or body.error
                        handleError err, body, "Install home failed"
                    else
                        waitInstallComplete body.app.slug, (err, appresult) ->
                            if not err? and appresult.state is "installed"
                                console.log "#{app} successfully installed"
                            else
                                handleError null, null, "Install home failed"

# Uninstall
program
    .command("uninstall <app>")
    .description("Remove application")
    .action (app) ->
        console.log "Uninstall started for #{app}..."
        if app in ['datasystem', 'home', 'proxy', 'couchdb']
            manifest.name = app
            manifest.user = app
            client.clean manifest, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Uninstall failed"
                else
                    console.log "#{app} successfully uninstalled"
        else
            getHomePort (homeport) ->
                path = "api/applications/#{app}/uninstall"
                homeClient = new Client "http://localhost:#{homeport}/"
                homeClient.del path, (err, res, body) ->
                    if err or res.statusCode isnt 200
                        handleError err, body, "Uninstall home failed"
                    else
                        console.log "#{app} successfully uninstalled"

# Start
program
    .command("start <app>")
    .description("Start application")
    .action (app) ->
        console.log "Starting #{app}..."
        if app in ['datasystem', 'home', 'proxy', 'couchdb']
            manifest.name = app
            manifest.repository.url =
                "https://github.com/mycozycloud/cozy-#{app}.git"
            manifest.user = app
            client.stop app, (err, res, body) ->
                client.start manifest, (err, res, body) ->
                    if err or body.error?
                        handleError err, body, "Start failed"
                    else
                        console.log "#{app} successfully started"
        else
            find = false
            getHomePort (homeport) ->
                homeClient = new Client "http://localhost:#{homeport}/"
                homeClient.get "api/applications/", (err, res, apps) ->
                    if apps? and apps.rows?
                        for manifest in apps.rows
                            if manifest.name is app
                                find = true
                                path = "api/applications/#{manifest.slug}/start"
                                homeClient.post path, manifest, (err, res, body) ->
                                    if err or body.error
                                        handleError err, body, "Start failed"
                                    else
                                        console.log "#{app} successfully started"
                        if not find
                            console.log "Start failed : application #{app} not found"
                    else
                        console.log "Start failed : no applications installed"

# Stop
program
    .command("stop <app>")
    .description("Stop application")
    .action (app) ->
        console.log "Stopping #{app}..."
        if app in ['datasystem', 'home', 'proxy', 'couchdb']
            manifest.name = app
            manifest.user = app
            client.stop app, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Stop failed"
                else
                    console.log "#{app} successfully stopped"
        else
            find = false
            getHomePort (homeport) ->
                homeClient = new Client "http://localhost:#{homeport}/"
                homeClient.get "api/applications/", (err, res, apps) ->
                    if apps? and apps.rows?
                        for manifest in apps.rows
                            if manifest.name is app
                                find = true
                                path = "api/applications/#{manifest.slug}/stop"
                                homeClient.post path, manifest, (err, res, body) ->
                                    if err or body.error
                                        handleError err, body, "Stop failed"
                                    else
                                        console.log "#{app} successfully stopperd"
                        if not find
                            console.log "Stop failed : application #{manifest.name} not found"
                    else
                        console.log "Stop failed : no applications installed"

# Restart
program
    .command("restart <app>")
    .description("Restart application")
    .action (app) ->
        console.log "Stopping #{app}..."
        if app in ['datasystem', 'home', 'proxy', 'couchdb']
            client.stop app, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Stop failed"
                else
                    console.log "#{app} successfully stopped"
                    console.log "Starting #{app}..."
                    manifest.name = app
                    manifest.repository.url =
                        "https://github.com/mycozycloud/cozy-#{app}.git"
                    manifest.user = app
                    client.start manifest, (err, res, body) ->
                        if err
                            handleError err, body, "Start failed"
                        else
                            console.log "#{app} sucessfully started"
        else
            getHomePort (homeport) ->
                homeClient = new Client "http://localhost:#{homeport}/"
                homeClient.post "api/applications/#{app}/stop", {}, (err, res, body) ->
                    if err or body.error?
                        handleError err, body, "Stop failed"
                    else
                        console.log "#{app} successfully stopped"
                        console.log "Starting #{app}..."
                        path = "api/applications/#{app}/start"
                        homeClient.post path, {}, (err, res, body) ->
                            if err
                                handleError err, body, "Start failed"
                            else
                                console.log "#{app} sucessfully started"

# Update
program
    .command("update <app>")
    .description("Update application")
    .action (app) ->
        console.log "Update #{app}..."
        if app in ['datasystem', 'home', 'proxy', 'couchdb']
            client.lightUpdate app, (err, res, body) ->
                if err or body.error?
                    handleError err, body, "Stop failed"
                else
                    console.log "#{app} successfully stopped"
                    console.log "Starting #{app}..."
                    manifest.name = app
                    manifest.repository.url =
                        "https://github.com/mycozycloud/cozy-#{app}.git"
                    manifest.user = app
                    client.start manifest, (err, res, body) ->
                        if err
                            handleError err, body, "Start failed"
                        else
                            console.log "#{app} sucessfully started"
        else
            getHomePort (homeport) ->
                homeClient = new Client "http://localhost:#{homeport}/"
                find = false
                homeClient.get "api/applications/", (err, res, apps) ->
                    if apps? and apps.rows?
                        for manifest in apps.rows
                            if manifest.name is app
                                find = true
                                path = "api/applications/#{manifest.slug}/update"
                                homeClient.put path, manifest, (err, res, body) ->
                                    if err or body.error
                                        handleError err, body, "Update failed"
                                    else
                                        console.log "#{app} successfully updated"
                        if not find
                            console.log "Update failed : application #{app} not found"
                    else
                        console.log "Update failed : no applications installed"



program
    .command("*")
    .description("Display error message for an unknown command.")
    .action ->
        console.log 'Unknown command, run "dockmonitor --help"' + \
                    ' to know the list of available commands.'

program.parse process.argv
