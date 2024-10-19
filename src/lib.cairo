mod types;

mod library {
    mod eth;
    mod red_black_tree;
    mod utils;
    mod pricing_utils;
    mod constants;
}


mod vault {
    mod interface;
    mod contract;
}

mod option_round {
    mod interface;
    mod contract;
}

mod fossil_client {
    mod interface;
    mod contract;
}

#[cfg(test)]
mod tests;
