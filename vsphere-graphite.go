package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path"
	"reflect"
	"runtime/pprof"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cblomart/vsphere-graphite/backend"
	"github.com/cblomart/vsphere-graphite/config"
	"github.com/cblomart/vsphere-graphite/vsphere"

	"github.com/takama/daemon"

	"github.com/vmware/govmomi/vim25/types"
)

const (
	// name of the service
	name        = "vsphere-graphite"
	description = "send vsphere stats to graphite"
)

var dependencies = []string{}

var stdlog, errlog *log.Logger

// Service has embedded daemon
type Service struct {
	daemon.Daemon
}

// EntityQuery : Informations to query about an entity
type EntityQuery struct {
	Name    string
	Entity  types.ManagedObjectReference
	Metrics []int
}

func queryVCenter(vcenter vsphere.VCenter, config config.Configuration, channel *chan []backend.Point) {
	vcenter.Query(config.Interval, config.Domain, channel)
}

// Manage by daemon commands or run the daemon
func (service *Service) Manage() (string, error) {

	usage := "Usage: vsphere-graphite install | remove | start | stop | status"

	// if received any kind of command, do it
	if len(os.Args) > 1 {
		command := os.Args[1]
		switch command {
		case "install":
			return service.Install()
		case "remove":
			return service.Remove()
		case "start":
			return service.Start()
		case "stop":
			return service.Stop()
		case "status":
			return service.Status()
		default:
			return usage, nil
		}
	}

	stdlog.Println("Starting daemon:", path.Base(os.Args[0]))

	// read the configuration
	file, err := os.Open("/etc/" + path.Base(os.Args[0]) + ".json")
	if err != nil {
		return "Could not open configuration file", err
	}
	jsondec := json.NewDecoder(file)
	config := config.Configuration{}
	err = jsondec.Decode(&config)
	if err != nil {
		return "Could not decode configuration file", err
	}

	if config.Profiling {
		f, err := os.Create("/tmp/vsphere-graphite-cpu.profile")
		if err != nil {
			log.Fatal("could not create CPU profile: ", err)
		}
		if err := pprof.StartCPUProfile(f); err != nil {
			log.Fatal("could not start CPU profile: ", err)
		}
		defer pprof.StopCPUProfile()
	}

	//force backend values to environement varialbles if present
	s := reflect.ValueOf(&config.Backend).Elem()
	numfields := s.NumField()
	for i := 0; i < numfields; i++ {
		f := s.Field(i)
		if f.CanSet() {
			//exported field
			envname := strings.ToUpper(s.Type().Name() + "_" + s.Type().Field(i).Name)
			envval := os.Getenv(envname)
			if len(envval) > 0 {
				//environment variable set with name
				switch ftype := f.Type().Name(); ftype {
				case "string":
					f.SetString(envval)
				case "int":
					val, err := strconv.ParseInt(envval, 10, 64)
					if err == nil {
						f.SetInt(val)
					}
				}
			}
		}
	}

	for _, vcenter := range config.VCenters {
		vcenter.Init(config.Metrics, stdlog, errlog)
	}

	err = config.Backend.Init(stdlog, errlog)
	if err != nil {
		return "Could not initialize backend", err
	}
	defer config.Backend.Disconnect()

	// Set up channel on which to send signal notifications.
	// We must use a buffered channel or risk missing the signal
	// if we're not ready to receive when the signal is sent.
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt, os.Kill, syscall.SIGTERM)

	// Set up a channel to receive the metrics
	metrics := make(chan []backend.Point)

	// Recover from panic
	defer func() {
		if r := recover(); r != nil {
			fmt.Println("Critical - recovered from panic ", r)
		}
	}()

	// Set up a ticker to collect metrics at givent interval
	ticker := time.NewTicker(time.Second * time.Duration(config.Interval))
	defer ticker.Stop()

	// Start retriveing and sending metrics
	stdlog.Println("Retrieving metrics")
	for _, vcenter := range config.VCenters {
		go queryVCenter(*vcenter, config, &metrics)
	}
	for {
		select {
		case values := <-metrics:
			config.Backend.SendMetrics(values)
			stdlog.Printf("Sent %d logs to backend", len(values))
		case <-ticker.C:
			stdlog.Println("Retrieving metrics")
			for _, vcenter := range config.VCenters {
				go queryVCenter(*vcenter, config, &metrics)
			}
		case killSignal := <-interrupt:
			stdlog.Println("Got signal:", killSignal)
			if killSignal == os.Interrupt {
				return "Daemon was interrupted by system signal", nil
			}
			return "Daemon was killed", nil
		}
	}
}

func init() {
	stdlog = log.New(os.Stdout, "", log.Ldate|log.Ltime)
	errlog = log.New(os.Stderr, "", log.Ldate|log.Ltime)
}

func main() {
	srv, err := daemon.New(name, description, dependencies...)
	if err != nil {
		errlog.Println("Error: ", err)
		os.Exit(1)
	}
	service := &Service{srv}
	status, err := service.Manage()
	if err != nil {
		errlog.Println(status, "Error: ", err)
		os.Exit(1)
	}
	fmt.Println(status)
}
