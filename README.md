# cpulimit-daemon
A daemon to continuously limit the CPU utilization of one or more processes to a specific percentage.

# How to use

To use this script you have to download it from this repo.

## Requirements

Since this script relies on [cpulimit](https://github.com/opsengine/cpulimit), it has to be available on your system.

On Arch Linux it can be installed using
```shell
sudo pacman -S cpulimit
```

## Usage

```
>> ./cpulimit-daemon 
Usage: cpulimit-daemon [-f] -e "myprocess.*-some -process -arguments" -p 100
```

## Parameters

| Name | Type    | Description |
|------|---------|-------------|
| `-f` | Flag    | Whether to apply the expression to the full command (including arguments) |
| `-e` | ERE     | Expression to match processes with |
| `-p` | Integer | CPU usage percentage limit |

## Examples

```shell
sudo ./cpulimit-daemon -e chrome -p 50
```

# Why is my shell application stopped
This is "expected behaviour", see here:  
https://unix.stackexchange.com/questions/124126/why-cpulimit-makes-process-stopped
