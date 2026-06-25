pub const ParseError = error{
    MissingValue,
    InvalidValue,
    UnknownOption,
    MissingCommand,
    UnknownCommand,
    Help,
    OutOfMemory,
    TooManyValues,
    TooManyPositionals,
};
