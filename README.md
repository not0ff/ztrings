# ztrings

*ztrings* is a partial implementation of the GNU binutils *strings* command-line tool in the Zig programming language

## Usage
Print  ascii-encoded strings from a file:
```
$ ztrings <filename>
```

List all available options:
```
$ ztrings -h
Usage: ztrings [option(s)] [files(s)]
    
    Options:
      -f               Print the name of the file before each string
      -n min-len       The minimum number of characters to print a string (default: 4)
      -t  {o,d,x}      Print the location of string in the file in base 8, 10 or 16
      -h               Print the program usage
      -v               Print the version of the program
    
    Arguments:
      file1 [ file2 file3... ]     List of files to scan
    
```

## Compiling
The project should be built with version 0.16.0 of Zig<br>
- Step 1: clone the repository
```
$ git clone https://github.com/not0ff/ztrings.git
```
- Step 2: build using Zig <br>
  - Run directly:
    ```
    $ zig build run -- [option(s)] [files(s)]
    ```
  - Save the binary in *zig-out/bin*:
    ```
    $ zig build -Drelease=true  
    $ ./zig-out/bin/ztrings [option(s)] [files(s)]
    ```
- Step 3 (Optional): run unit tests
```
$ zig build test --summary all
```
